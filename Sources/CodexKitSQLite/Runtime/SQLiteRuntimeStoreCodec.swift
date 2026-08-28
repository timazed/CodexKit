import Foundation
import CodexKit
import GRDB

extension SQLiteRuntimeStorePersistence {
    func replaceDatabaseContents(
        with normalized: StoredRuntimeState,
        in db: Database
    ) throws {
        let threadRows = try normalized.threads.map { thread in
            try makeThreadRow(
                from: thread,
                nextHistorySequence: normalized.nextHistorySequenceByThread[thread.id] ?? 1
            )
        }
        let summaryRows = try normalized.threads.compactMap { thread -> RuntimeSummaryRow? in
            guard let summary = normalized.summariesByThread[thread.id] else {
                return nil
            }
            return try makeSummaryRow(from: summary)
        }
        let historyRows = try normalized.historyByThread.values
            .flatMap { $0 }
            .map(makeHistoryRow)
        let structuredOutputRows = try self.structuredOutputRows(from: normalized.historyByThread)
        let contextRows = try normalized.contextStateByThread.values.map(makeContextStateRow)
        try enqueueEveryAttachmentReferenceForCleanup(in: db)

        try RuntimeAttachmentReferenceRow.deleteAll(db)
        try RuntimeContextStateRow.deleteAll(db)
        try RuntimeStructuredOutputRow.deleteAll(db)
        try RuntimeHistoryRow.deleteAll(db)
        try RuntimeSummaryRow.deleteAll(db)
        try RuntimeThreadRow.deleteAll(db)

        for row in threadRows { try row.insert(db) }
        for row in summaryRows { try row.insert(db) }
        for row in historyRows {
            try row.insert(db)
            try replaceAttachmentReferences(
                ownerType: "history",
                ownerKey: row.storageID,
                threadID: row.threadID,
                storageKeys: try attachmentStorageKeys(from: row),
                in: db
            )
        }
        for row in structuredOutputRows { try row.insert(db) }
        for row in contextRows {
            try row.insert(db)
            try replaceAttachmentReferences(
                ownerType: "context",
                ownerKey: row.threadID,
                threadID: row.threadID,
                storageKeys: try attachmentStorageKeys(from: row),
                in: db
            )
        }
        try removeStillReferencedAttachmentsFromCleanup(in: db)
    }

    func makeThreadRow(
        from thread: AgentThread,
        nextHistorySequence: Int = 1
    ) throws -> RuntimeThreadRow {
        RuntimeThreadRow(
            threadID: thread.id,
            createdAt: thread.createdAt.timeIntervalSince1970,
            updatedAt: thread.updatedAt.timeIntervalSince1970,
            status: thread.status.rawValue,
            nextHistorySequence: nextHistorySequence,
            encodedThread: try encodeBoundedRuntimePayload(thread, name: "thread")
        )
    }

    func makeSummaryRow(from summary: AgentThreadSummary) throws -> RuntimeSummaryRow {
        RuntimeSummaryRow(
            threadID: summary.threadID,
            createdAt: summary.createdAt.timeIntervalSince1970,
            updatedAt: summary.updatedAt.timeIntervalSince1970,
            latestItemAt: summary.latestItemAt?.timeIntervalSince1970,
            itemCount: summary.itemCount,
            pendingStateKind: summary.pendingState?.kind.rawValue,
            latestStructuredOutputFormatName: summary.latestStructuredOutputMetadata?.formatName,
            encodedSummary: try encodeBoundedRuntimePayload(summary, name: "thread summary")
        )
    }

    func makeHistoryRow(from record: AgentHistoryRecord) throws -> RuntimeHistoryRow {
        let persisted = try PersistedAgentHistoryRecord(
            record: record,
            attachmentStore: attachmentStore,
            preparedAttachments: preparedAttachments
        )
        return RuntimeHistoryRow(
            storageID: "\(record.item.threadID):\(record.sequenceNumber)",
            recordID: record.id,
            threadID: record.item.threadID,
            sequenceNumber: record.sequenceNumber,
            createdAt: record.createdAt.timeIntervalSince1970,
            kind: record.item.kind.rawValue,
            turnID: record.item.turnID,
            relationshipKey: record.item.relationshipKey,
            isCompactionMarker: record.item.isCompactionMarker,
            isRedacted: record.redaction != nil,
            messageRole: record.item.messageRole?.rawValue,
            hasStructuredOutput: record.item.hasQueryableStructuredOutput,
            systemEventType: record.item.systemEventType?.rawValue,
            encodedRecord: try encodeBoundedRuntimePayload(persisted, name: "history record")
        )
    }

    func makeContextStateRow(from state: AgentThreadContextState) throws -> RuntimeContextStateRow {
        let persisted = try PersistedAgentThreadContextState(
            state: state,
            attachmentStore: attachmentStore,
            preparedAttachments: preparedAttachments
        )
        return RuntimeContextStateRow(
            threadID: state.threadID,
            generation: state.generation,
            encodedState: try encodeBoundedRuntimePayload(persisted, name: "context state")
        )
    }

    func structuredOutputRows(
        from historyByThread: [String: [AgentHistoryRecord]]
    ) throws -> [RuntimeStructuredOutputRow] {
        try historyByThread.values
            .flatMap { $0 }
            .compactMap { record -> RuntimeStructuredOutputRow? in
                switch record.item {
                case let .structuredOutput(output):
                    return try makeStructuredOutputRow(
                        id: structuredOutputID(
                            threadID: output.threadID,
                            kind: "structured",
                            recordID: record.id
                        ),
                        record: output
                    )
                case let .message(message):
                    guard let metadata = message.structuredOutput else {
                        return nil
                    }
                    return try makeStructuredOutputRow(
                        id: structuredOutputID(
                            threadID: message.threadID,
                            kind: "message",
                            recordID: message.id
                        ),
                        record: AgentStructuredOutputRecord(
                            threadID: message.threadID,
                            turnID: "",
                            messageID: message.id,
                            metadata: metadata,
                            committedAt: message.createdAt
                        )
                    )
                default:
                    return nil
                }
            }
    }

    func makeStructuredOutputRow(
        id: String,
        record: AgentStructuredOutputRecord
    ) throws -> RuntimeStructuredOutputRow {
        RuntimeStructuredOutputRow(
            outputID: id,
            threadID: record.threadID,
            formatName: record.metadata.formatName,
            committedAt: record.committedAt.timeIntervalSince1970,
            encodedRecord: try encodeBoundedRuntimePayload(record, name: "structured output")
        )
    }

    func structuredOutputID(
        threadID: String,
        kind: String,
        recordID: String
    ) -> String {
        "t\(threadID.utf8.count):\(threadID)k\(kind.utf8.count):\(kind)r\(recordID.utf8.count):\(recordID)"
    }

    func structuredOutputIDs(from record: AgentHistoryRecord) -> [String] {
        let kind: String
        let recordID: String
        switch record.item {
        case .structuredOutput:
            kind = "structured"
            recordID = record.id
        case let .message(message) where message.structuredOutput != nil:
            kind = "message"
            recordID = message.id
        default:
            return []
        }
        let legacyID = "\(kind):\(recordID)"
        return [
            structuredOutputID(
                threadID: record.item.threadID,
                kind: kind,
                recordID: recordID
            ),
            "\(record.item.threadID):\(legacyID)",
            legacyID,
        ]
    }

    func decodeThread(from row: RuntimeThreadRow) throws -> AgentThread {
        try validateBoundedRuntimePayload(row.encodedThread, name: "stored thread")
        let thread = try JSONDecoder().decode(AgentThread.self, from: row.encodedThread)
        try AgentStoreLimitValidator.validateLoadedThread(thread, expectedID: row.threadID)
        guard thread.createdAt.timeIntervalSince1970 == row.createdAt,
              thread.updatedAt.timeIntervalSince1970 == row.updatedAt,
              thread.status.rawValue == row.status,
              row.nextHistorySequence > 0 else {
            throw AgentStoreError.invalidInput(
                "stored thread payload does not match its indexed projection"
            )
        }
        return thread
    }

    func decodeSummary(from row: RuntimeSummaryRow) throws -> AgentThreadSummary {
        try validateBoundedRuntimePayload(row.encodedSummary, name: "stored summary")
        let summary = try JSONDecoder().decode(
            AgentThreadSummary.self,
            from: row.encodedSummary
        )
        try AgentStoreLimitValidator.validateLoadedSummary(
            summary,
            expectedThreadID: row.threadID
        )
        guard summary.createdAt.timeIntervalSince1970 == row.createdAt,
              summary.updatedAt.timeIntervalSince1970 == row.updatedAt,
              summary.latestItemAt?.timeIntervalSince1970 == row.latestItemAt,
              summary.itemCount == row.itemCount,
              summary.pendingState?.kind.rawValue == row.pendingStateKind,
              summary.latestStructuredOutputMetadata?.formatName
                == row.latestStructuredOutputFormatName else {
            throw AgentStoreError.invalidInput(
                "stored summary payload does not match its indexed projection"
            )
        }
        return summary
    }

    func decodeContextState(from row: RuntimeContextStateRow) throws -> AgentThreadContextState {
        try validateBoundedRuntimePayload(row.encodedState, name: "stored context state")
        let decoder = JSONDecoder()
        let state: AgentThreadContextState
        if let persisted = try? decoder.decode(
            PersistedAgentThreadContextState.self,
            from: row.encodedState
        ) {
            state = try persisted.decode(using: attachmentStore)
        } else {
            state = try decoder.decode(AgentThreadContextState.self, from: row.encodedState)
        }
        try AgentStoreLimitValidator.validateLoadedContextState(
            state,
            expectedThreadID: row.threadID
        )
        guard state.generation == row.generation else {
            throw AgentStoreError.invalidInput(
                "stored context payload does not match its indexed projection"
            )
        }
        return state
    }

    func decodeHistoryRecord(from row: RuntimeHistoryRow) throws -> AgentHistoryRecord {
        try validateBoundedRuntimePayload(row.encodedRecord, name: "stored history record")
        let decoder = JSONDecoder()
        let record: AgentHistoryRecord
        if let persisted = try? decoder.decode(PersistedAgentHistoryRecord.self, from: row.encodedRecord) {
            record = try persisted.decode(using: attachmentStore)
        } else {
            record = try decoder.decode(AgentHistoryRecord.self, from: row.encodedRecord)
        }
        try AgentStoreLimitValidator.validateLoadedHistoryRecord(
            record,
            expectedThreadID: row.threadID
        )
        try validateHistoryProjection(record, row: row)
        return record
    }

    func decodeHistoryRecordForProjection(from row: RuntimeHistoryRow) throws -> AgentHistoryRecord {
        try validateBoundedRuntimePayload(row.encodedRecord, name: "stored history record")
        let decoder = JSONDecoder()
        let record: AgentHistoryRecord
        if let persisted = try? decoder.decode(PersistedAgentHistoryRecord.self, from: row.encodedRecord) {
            record = try persisted.decodeForProjection(using: attachmentStore)
        } else {
            record = try decoder.decode(AgentHistoryRecord.self, from: row.encodedRecord)
        }
        try AgentStoreLimitValidator.validateLoadedHistoryRecord(
            record,
            expectedThreadID: row.threadID
        )
        try validateHistoryProjection(record, row: row)
        return record
    }

    func attachmentStorageKeys(from row: RuntimeHistoryRow) throws -> Set<String> {
        try validateBoundedRuntimePayload(row.encodedRecord, name: "stored history record")
        let decoder = JSONDecoder()
        if let persisted = try? decoder.decode(PersistedAgentHistoryRecord.self, from: row.encodedRecord) {
            try persisted.validateAttachmentReferences(using: attachmentStore)
            return Set(persisted.attachmentStorageKeys)
        }
        return []
    }

    func attachmentStorageKeys(from row: RuntimeContextStateRow) throws -> Set<String> {
        try validateBoundedRuntimePayload(row.encodedState, name: "stored context state")
        let decoder = JSONDecoder()
        if let persisted = try? decoder.decode(
            PersistedAgentThreadContextState.self,
            from: row.encodedState
        ) {
            try persisted.validate(using: attachmentStore)
            return Set(persisted.attachmentStorageKeys)
        }
        return []
    }

    func referencedAttachmentStorageKeyBatch(
        after cursor: String?,
        limit: Int = 256,
        in db: Database
    ) throws -> [String] {
        var request = RuntimeAttachmentReferenceRow
            .select(Column("storageKey"), as: String.self)
            .distinct()
            .order(Column("storageKey").asc)
        if let cursor {
            request = request.filter(Column("storageKey") > cursor)
        }
        return try request.limit(limit).fetchAll(db)
    }

    private func enqueueEveryAttachmentReferenceForCleanup(in db: Database) throws {
        try db.execute(sql: """
            INSERT OR IGNORE INTO \(RuntimeAttachmentCleanupRow.databaseTableName) (storageKey)
            SELECT DISTINCT storageKey
            FROM \(RuntimeAttachmentReferenceRow.databaseTableName)
            """)
    }

    private func removeStillReferencedAttachmentsFromCleanup(in db: Database) throws {
        try db.execute(sql: """
            DELETE FROM \(RuntimeAttachmentCleanupRow.databaseTableName)
            WHERE storageKey IN (
                SELECT storageKey FROM \(RuntimeAttachmentReferenceRow.databaseTableName)
            )
            """)
    }

    func referencedAttachmentStorageKeys(
        among storageKeys: Set<String>,
        in db: Database
    ) throws -> Set<String> {
        guard !storageKeys.isEmpty else { return [] }
        return Set(try RuntimeAttachmentReferenceRow
            .filter(Array(storageKeys).contains(Column("storageKey")))
            .select(Column("storageKey"), as: String.self)
            .distinct()
            .fetchAll(db))
    }

    func enqueueAttachmentReferencesForCleanup(
        threadID: String,
        in db: Database
    ) throws {
        try db.execute(
            sql: """
            INSERT OR IGNORE INTO \(RuntimeAttachmentCleanupRow.databaseTableName) (storageKey)
            SELECT DISTINCT storageKey
            FROM \(RuntimeAttachmentReferenceRow.databaseTableName)
            WHERE threadID = ?
            """,
            arguments: [threadID]
        )
    }

    func attachmentReferenceStorageKeys(
        ownerType: String,
        ownerKey: String,
        in db: Database
    ) throws -> Set<String> {
        let limit = AgentStoreLimits.maximumImageCountPerWrite + 1
        let keys = try RuntimeAttachmentReferenceRow
            .filter(Column("ownerType") == ownerType)
            .filter(Column("ownerKey") == ownerKey)
            .select(Column("storageKey"), as: String.self)
            .limit(limit)
            .fetchAll(db)
        guard keys.count < limit else {
            throw AgentStoreError.invalidInput(
                "stored attachment references exceed their bounded limit"
            )
        }
        return Set(keys)
    }

    func replaceAttachmentReferences(
        ownerType: String,
        ownerKey: String,
        threadID: String,
        storageKeys: some Sequence<String>,
        in db: Database
    ) throws {
        try deleteAttachmentReferences(ownerType: ownerType, ownerKey: ownerKey, in: db)
        for storageKey in Set(storageKeys) {
            try RuntimeAttachmentReferenceRow(
                ownerType: ownerType,
                ownerKey: ownerKey,
                threadID: threadID,
                storageKey: storageKey
            ).insert(db)
        }
    }

    func deleteAttachmentReferences(
        ownerType: String,
        ownerKey: String,
        in db: Database
    ) throws {
        try RuntimeAttachmentReferenceRow
            .filter(Column("ownerType") == ownerType)
            .filter(Column("ownerKey") == ownerKey)
            .deleteAll(db)
    }

    func enqueueAttachmentCleanup(
        _ storageKeys: some Sequence<String>,
        in db: Database
    ) throws {
        for storageKey in Set(storageKeys) {
            try db.execute(
                sql: "INSERT OR IGNORE INTO \(RuntimeAttachmentCleanupRow.databaseTableName) (storageKey) VALUES (?)",
                arguments: [storageKey]
            )
        }
    }

    func decodeStructuredOutputRecord(from row: RuntimeStructuredOutputRow) throws -> AgentStructuredOutputRecord {
        try validateBoundedRuntimePayload(row.encodedRecord, name: "stored structured output")
        let record = try JSONDecoder().decode(
            AgentStructuredOutputRecord.self,
            from: row.encodedRecord
        )
        try AgentStoreLimitValidator.validateLoadedStructuredOutput(
            record,
            expectedThreadID: row.threadID
        )
        guard record.metadata.formatName == row.formatName,
              record.committedAt.timeIntervalSince1970 == row.committedAt else {
            throw AgentStoreError.invalidInput(
                "stored structured output does not match its indexed projection"
            )
        }
        return record
    }

    private func validateHistoryProjection(
        _ record: AgentHistoryRecord,
        row: RuntimeHistoryRow
    ) throws {
        guard record.id == row.recordID,
              record.sequenceNumber == row.sequenceNumber,
              record.createdAt.timeIntervalSince1970 == row.createdAt,
              record.item.kind.rawValue == row.kind,
              record.item.turnID == row.turnID,
              record.item.isCompactionMarker == row.isCompactionMarker,
              (record.redaction != nil) == row.isRedacted,
              record.item.messageRole?.rawValue == row.messageRole,
              record.item.hasQueryableStructuredOutput == row.hasStructuredOutput,
              record.item.systemEventType?.rawValue == row.systemEventType else {
            throw AgentStoreError.invalidInput(
                "stored history payload does not match its indexed projection"
            )
        }
    }

    func sqlPlaceholders(count: Int) -> String {
        "(" + Array(repeating: "?", count: count).joined(separator: ", ") + ")"
    }
}
