import Foundation
import GRDB

extension SQLiteRuntimeStateStore {
    func shouldImportLegacyState() async throws -> Bool {
        guard let legacyStateURL else {
            return false
        }
        guard legacyStateURL != url else {
            return false
        }
        guard FileManager.default.fileExists(atPath: legacyStateURL.path) else {
            return false
        }
        guard !databaseExistedAtInitialization else {
            return false
        }

        let threadCount = try await dbQueue.read { db in
            try RuntimeThreadCountQuery().execute(in: db)
        }
        return threadCount == 0
    }

    func importLegacyState() async throws {
        guard let legacyStateURL else {
            return
        }

        let legacyStore = FileRuntimeStateStore(
            url: legacyStateURL,
            logging: logger.configuration
        )
        let state = try await legacyStore.loadState().normalized()
        guard !state.threads.isEmpty || !state.historyByThread.isEmpty else {
            return
        }

        let persistence = self.persistence
        try await dbQueue.write { db in
            try attachmentStore.reset()
            try persistence.replaceDatabaseContents(with: state, in: db)
        }
    }

    func readUserVersion() async throws -> Int {
        try await dbQueue.read { db in
            try RuntimeUserVersionQuery().execute(in: db)
        }
    }
}

struct SQLiteRuntimeStorePersistence: Sendable {
    let attachmentStore: RuntimeAttachmentStore

    func apply(
        _ operations: [AgentStoreWriteOperation],
        in db: Database
    ) throws {
        let explicitlyUpdatedSummaryThreadIDs = Set(operations.compactMap { operation -> String? in
            guard case let .upsertSummary(threadID, _) = operation else { return nil }
            return threadID
        })

        // A newly created thread must exist before its summary and history rows
        // can satisfy their foreign keys, regardless of coalescing order.
        for operation in operations {
            guard case let .upsertThread(thread) = operation else { continue }
            try makeThreadRow(from: thread).save(db)
            if let summaryRow = try RuntimeSummaryRow.fetchOne(db, key: thread.id) {
                let summary = try decodeSummary(from: summaryRow)
                try makeSummaryRow(from: AgentThreadSummary(
                    threadID: summary.threadID,
                    createdAt: thread.createdAt,
                    updatedAt: thread.updatedAt,
                    latestItemAt: summary.latestItemAt,
                    itemCount: summary.itemCount,
                    latestAssistantMessagePreview: summary.latestAssistantMessagePreview,
                    latestStructuredOutputMetadata: summary.latestStructuredOutputMetadata,
                    latestPartialStructuredOutput: summary.latestPartialStructuredOutput,
                    latestToolState: summary.latestToolState,
                    latestTurnStatus: summary.latestTurnStatus,
                    pendingState: summary.pendingState
                )).save(db)
            } else {
                let summary = StoredRuntimeState(threads: [thread])
                    .threadSummaryFallback(for: thread)
                try makeSummaryRow(from: summary).save(db)
            }
        }

        for operation in operations {
            switch operation {
            case .upsertThread:
                continue

            case let .upsertSummary(_, summary):
                try makeSummaryRow(from: summary).save(db)

            case let .appendHistoryItems(threadID, items):
                try appendHistoryItems(items, to: threadID, in: db)
                if !explicitlyUpdatedSummaryThreadIDs.contains(threadID) {
                    try updateSummaryAfterAppending(items, threadID: threadID, in: db)
                }

            case let .appendCompactionMarker(threadID, marker):
                try appendHistoryItems([marker], to: threadID, in: db)
                if !explicitlyUpdatedSummaryThreadIDs.contains(threadID) {
                    try updateSummaryAfterAppending([marker], threadID: threadID, in: db)
                }

            case let .upsertThreadContextState(threadID, state):
                if let state {
                    try makeContextStateRow(from: state).save(db)
                } else {
                    _ = try RuntimeContextStateRow.deleteOne(db, key: threadID)
                }

            case let .deleteThreadContextState(threadID):
                _ = try RuntimeContextStateRow.deleteOne(db, key: threadID)

            case let .setPendingState(threadID, pendingState):
                try updateSummary(threadID: threadID, in: db) { summary in
                    AgentThreadSummary(
                        threadID: summary.threadID,
                        createdAt: summary.createdAt,
                        updatedAt: summary.updatedAt,
                        latestItemAt: summary.latestItemAt,
                        itemCount: summary.itemCount,
                        latestAssistantMessagePreview: summary.latestAssistantMessagePreview,
                        latestStructuredOutputMetadata: summary.latestStructuredOutputMetadata,
                        latestPartialStructuredOutput: summary.latestPartialStructuredOutput,
                        latestToolState: summary.latestToolState,
                        latestTurnStatus: summary.latestTurnStatus,
                        pendingState: pendingState
                    )
                }

            case let .setPartialStructuredSnapshot(threadID, snapshot):
                try updateSummary(threadID: threadID, in: db) { summary in
                    AgentThreadSummary(
                        threadID: summary.threadID,
                        createdAt: summary.createdAt,
                        updatedAt: summary.updatedAt,
                        latestItemAt: summary.latestItemAt,
                        itemCount: summary.itemCount,
                        latestAssistantMessagePreview: summary.latestAssistantMessagePreview,
                        latestStructuredOutputMetadata: summary.latestStructuredOutputMetadata,
                        latestPartialStructuredOutput: snapshot,
                        latestToolState: summary.latestToolState,
                        latestTurnStatus: summary.latestTurnStatus,
                        pendingState: summary.pendingState
                    )
                }

            case let .upsertToolSession(threadID, session):
                try updateSummary(threadID: threadID, in: db) { summary in
                    let latestToolState = AgentLatestToolState(
                        invocationID: session.invocationID,
                        turnID: session.turnID,
                        toolName: session.toolName,
                        status: .running,
                        success: nil,
                        sessionID: session.sessionID,
                        sessionStatus: session.sessionStatus,
                        metadata: session.metadata,
                        resumable: session.resumable,
                        updatedAt: session.updatedAt,
                        resultPreview: nil
                    )
                    return AgentThreadSummary(
                        threadID: summary.threadID,
                        createdAt: summary.createdAt,
                        updatedAt: summary.updatedAt,
                        latestItemAt: summary.latestItemAt,
                        itemCount: summary.itemCount,
                        latestAssistantMessagePreview: summary.latestAssistantMessagePreview,
                        latestStructuredOutputMetadata: summary.latestStructuredOutputMetadata,
                        latestPartialStructuredOutput: summary.latestPartialStructuredOutput,
                        latestToolState: latestToolState,
                        latestTurnStatus: summary.latestTurnStatus,
                        pendingState: .toolWait(
                            AgentPendingToolWaitState(
                                invocationID: session.invocationID,
                                turnID: session.turnID,
                                toolName: session.toolName,
                                startedAt: session.updatedAt,
                                sessionID: session.sessionID,
                                sessionStatus: session.sessionStatus,
                                metadata: session.metadata,
                                resumable: session.resumable
                            )
                        )
                    )
                }

            case let .redactHistoryItems(threadID, itemIDs, reason):
                try redactHistoryItems(itemIDs, in: threadID, reason: reason, database: db)

            case let .deleteThread(threadID):
                _ = try RuntimeThreadRow.deleteOne(db, key: threadID)
                try attachmentStore.removeThread(threadID)
            }
        }
    }

    private func appendHistoryItems(
        _ items: [AgentHistoryRecord],
        to threadID: String,
        in db: Database
    ) throws {
        guard !items.isEmpty else { return }
        var expectedSequence = try RuntimeNextHistorySequenceQuery(threadID: threadID)
            .execute(in: db)

        for item in items {
            guard item.item.threadID == threadID,
                  item.sequenceNumber == expectedSequence
            else {
                throw AgentRuntimeError(
                    code: "invalid_history_sequence",
                    message: "Expected history sequence \(expectedSequence) for thread \(threadID), received \(item.sequenceNumber)."
                )
            }
            try makeHistoryRow(from: item).insert(db)
            for structuredOutputRow in try structuredOutputRows(from: [threadID: [item]]) {
                try structuredOutputRow.save(db)
            }
            expectedSequence += 1
        }
    }

    private func updateSummary(
        threadID: String,
        in db: Database,
        transform: (AgentThreadSummary) -> AgentThreadSummary
    ) throws {
        guard let threadRow = try RuntimeThreadRow.fetchOne(db, key: threadID) else {
            throw AgentRuntimeError.threadNotFound(threadID)
        }
        let thread = try decodeThread(from: threadRow)
        let current: AgentThreadSummary
        if let summaryRow = try RuntimeSummaryRow.fetchOne(db, key: threadID) {
            current = try decodeSummary(from: summaryRow)
        } else {
            current = StoredRuntimeState(threads: [thread]).threadSummaryFallback(for: thread)
        }
        try makeSummaryRow(from: transform(current)).save(db)
    }

    private func updateSummaryAfterAppending(
        _ items: [AgentHistoryRecord],
        threadID: String,
        in db: Database
    ) throws {
        guard !items.isEmpty else { return }
        guard let threadRow = try RuntimeThreadRow.fetchOne(db, key: threadID) else {
            throw AgentRuntimeError.threadNotFound(threadID)
        }
        let thread = try decodeThread(from: threadRow)
        try updateSummary(threadID: threadID, in: db) { current in
            let projected = StoredRuntimeStateProjectionBuilder().rebuildSummary(
                for: thread,
                history: items,
                existing: current
            )
            return AgentThreadSummary(
                threadID: projected.threadID,
                createdAt: projected.createdAt,
                updatedAt: projected.updatedAt,
                latestItemAt: items.last?.createdAt ?? current.latestItemAt,
                itemCount: (current.itemCount ?? 0) + items.count,
                latestAssistantMessagePreview: projected.latestAssistantMessagePreview,
                latestStructuredOutputMetadata: projected.latestStructuredOutputMetadata,
                latestPartialStructuredOutput: projected.latestPartialStructuredOutput,
                latestToolState: projected.latestToolState,
                latestTurnStatus: projected.latestTurnStatus,
                pendingState: projected.pendingState
            )
        }
    }

    private func redactHistoryItems(
        _ itemIDs: [String],
        in threadID: String,
        reason: AgentRedactionReason?,
        database db: Database
    ) throws {
        guard !itemIDs.isEmpty else { return }
        let rows = try RuntimeHistoryRow
            .filter(Column("threadID") == threadID)
            .filter(itemIDs.contains(Column("recordID")))
            .fetchAll(db)
        for row in rows {
            let redacted = try decodeHistoryRecord(from: row).redacted(reason: reason)
            try makeHistoryRow(from: redacted).save(db)
        }
    }

    func replaceDatabaseContents(
        with normalized: StoredRuntimeState,
        in db: Database
    ) throws {
        let threadRows = try normalized.threads.map(makeThreadRow)
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

        try RuntimeContextStateRow.deleteAll(db)
        try RuntimeStructuredOutputRow.deleteAll(db)
        try RuntimeHistoryRow.deleteAll(db)
        try RuntimeSummaryRow.deleteAll(db)
        try RuntimeThreadRow.deleteAll(db)

        for row in threadRows { try row.insert(db) }
        for row in summaryRows { try row.insert(db) }
        for row in historyRows { try row.insert(db) }
        for row in structuredOutputRows { try row.insert(db) }
        for row in contextRows { try row.insert(db) }
    }

    func loadPartialState(
        for threadIDs: Set<String>,
        from db: Database
    ) throws -> StoredRuntimeState {
        guard !threadIDs.isEmpty else {
            return .empty
        }

        let ids = Array(threadIDs)
        let threadRows = try RuntimeThreadRow
            .filter(ids.contains(Column("threadID")))
            .fetchAll(db)
        let summaryRows = try RuntimeSummaryRow
            .filter(ids.contains(Column("threadID")))
            .fetchAll(db)
        let historyRows = try RuntimeHistoryRowsRequest(
            sql: """
            SELECT * FROM \(RuntimeHistoryRow.databaseTableName)
            WHERE threadID IN \(sqlPlaceholders(count: ids.count))
            ORDER BY threadID ASC, sequenceNumber ASC
            """,
            arguments: StatementArguments(ids)
        ).execute(in: db)
        let contextRows = try RuntimeContextStateRow
            .filter(ids.contains(Column("threadID")))
            .fetchAll(db)

        let threads = try threadRows.map(decodeThread)
        let summaries = try Dictionary<String, AgentThreadSummary>(
            uniqueKeysWithValues: summaryRows.map { ($0.threadID, try decodeSummary(from: $0)) }
        )
        let decodedHistoryRows = try historyRows.map(decodeHistoryRecord)
        let history = Dictionary(grouping: decodedHistoryRows, by: { $0.item.threadID })
        let contextState = try Dictionary<String, AgentThreadContextState>(
            uniqueKeysWithValues: contextRows.map { ($0.threadID, try decodeContextState(from: $0)) }
        )
        let nextSequence = history.mapValues { ($0.last?.sequenceNumber ?? 0) + 1 }

        return StoredRuntimeState(
            threads: threads,
            historyByThread: history,
            summariesByThread: summaries,
            contextStateByThread: contextState,
            nextHistorySequenceByThread: nextSequence
        )
    }

    func persistThreads(
        ids threadIDs: Set<String>,
        from state: StoredRuntimeState,
        in db: Database
    ) throws {
        let normalized = state.normalized()
        let threads = normalized.threads.filter { threadIDs.contains($0.id) }
        guard !threads.isEmpty else {
            return
        }

        for thread in threads {
            try makeThreadRow(from: thread).insert(db)
            if let summary = normalized.summariesByThread[thread.id] {
                try makeSummaryRow(from: summary).insert(db)
            }
            if let contextState = normalized.contextStateByThread[thread.id] {
                try makeContextStateRow(from: contextState).insert(db)
            }
            for record in normalized.historyByThread[thread.id] ?? [] {
                try makeHistoryRow(from: record).insert(db)
            }
        }

        for row in try structuredOutputRows(
            from: normalized.historyByThread.filter { threadIDs.contains($0.key) }
        ) {
            try row.insert(db)
        }
    }

    func deletePersistedThread(
        _ threadID: String,
        in db: Database
    ) throws {
        _ = try RuntimeThreadRow.deleteOne(db, key: threadID)
    }

    func makeThreadRow(from thread: AgentThread) throws -> RuntimeThreadRow {
        RuntimeThreadRow(
            threadID: thread.id,
            createdAt: thread.createdAt.timeIntervalSince1970,
            updatedAt: thread.updatedAt.timeIntervalSince1970,
            status: thread.status.rawValue,
            encodedThread: try JSONEncoder().encode(thread)
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
            encodedSummary: try JSONEncoder().encode(summary)
        )
    }

    func makeHistoryRow(from record: AgentHistoryRecord) throws -> RuntimeHistoryRow {
        let persisted = try PersistedAgentHistoryRecord(
            record: record,
            attachmentStore: attachmentStore
        )
        return RuntimeHistoryRow(
            storageID: "\(record.item.threadID):\(record.sequenceNumber)",
            recordID: record.id,
            threadID: record.item.threadID,
            sequenceNumber: record.sequenceNumber,
            createdAt: record.createdAt.timeIntervalSince1970,
            kind: record.item.kind.rawValue,
            turnID: record.item.turnID,
            isCompactionMarker: record.item.isCompactionMarker,
            isRedacted: record.redaction != nil,
            encodedRecord: try JSONEncoder().encode(persisted)
        )
    }

    func makeContextStateRow(from state: AgentThreadContextState) throws -> RuntimeContextStateRow {
        let persisted = try PersistedAgentThreadContextState(
            state: state,
            attachmentStore: attachmentStore
        )
        return RuntimeContextStateRow(
            threadID: state.threadID,
            generation: state.generation,
            encodedState: try JSONEncoder().encode(persisted)
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
                        id: "structured:\(record.id)",
                        record: output
                    )
                case let .message(message):
                    guard let metadata = message.structuredOutput else {
                        return nil
                    }
                    return try makeStructuredOutputRow(
                        id: "message:\(message.id)",
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
            encodedRecord: try JSONEncoder().encode(record)
        )
    }

    func decodeThread(from row: RuntimeThreadRow) throws -> AgentThread {
        try JSONDecoder().decode(AgentThread.self, from: row.encodedThread)
    }

    func decodeSummary(from row: RuntimeSummaryRow) throws -> AgentThreadSummary {
        try JSONDecoder().decode(AgentThreadSummary.self, from: row.encodedSummary)
    }

    func decodeContextState(from row: RuntimeContextStateRow) throws -> AgentThreadContextState {
        let decoder = JSONDecoder()
        if let persisted = try? decoder.decode(
            PersistedAgentThreadContextState.self,
            from: row.encodedState
        ) {
            return try persisted.decode(using: attachmentStore)
        }
        return try decoder.decode(AgentThreadContextState.self, from: row.encodedState)
    }

    func decodeHistoryRecord(from row: RuntimeHistoryRow) throws -> AgentHistoryRecord {
        let decoder = JSONDecoder()
        if let persisted = try? decoder.decode(PersistedAgentHistoryRecord.self, from: row.encodedRecord) {
            return try persisted.decode(using: attachmentStore)
        }
        return try decoder.decode(AgentHistoryRecord.self, from: row.encodedRecord)
    }

    func decodeStructuredOutputRecord(from row: RuntimeStructuredOutputRow) throws -> AgentStructuredOutputRecord {
        try JSONDecoder().decode(AgentStructuredOutputRecord.self, from: row.encodedRecord)
    }

    private func sqlPlaceholders(count: Int) -> String {
        "(" + Array(repeating: "?", count: count).joined(separator: ", ") + ")"
    }
}

struct SQLiteRuntimeStoreSchema: Sendable {
    let currentStoreSchemaVersion: Int

    func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("runtime_store_v1") { db in
            try db.create(table: RuntimeThreadRow.databaseTableName) { table in
                table.column("threadID", .text).primaryKey()
                table.column("createdAt", .double).notNull()
                table.column("updatedAt", .double).notNull()
                table.column("status", .text).notNull()
                table.column("encodedThread", .blob).notNull()
            }

            try db.create(table: RuntimeSummaryRow.databaseTableName) { table in
                table.column("threadID", .text)
                    .primaryKey()
                    .references(RuntimeThreadRow.databaseTableName, onDelete: .cascade)
                table.column("createdAt", .double).notNull()
                table.column("updatedAt", .double).notNull()
                table.column("latestItemAt", .double)
                table.column("itemCount", .integer)
                table.column("pendingStateKind", .text)
                table.column("latestStructuredOutputFormatName", .text)
                table.column("encodedSummary", .blob).notNull()
            }

            try db.create(table: RuntimeHistoryRow.databaseTableName) { table in
                table.column("storageID", .text).primaryKey()
                table.column("recordID", .text).notNull()
                table.column("threadID", .text)
                    .notNull()
                    .references(RuntimeThreadRow.databaseTableName, onDelete: .cascade)
                table.column("sequenceNumber", .integer).notNull()
                table.column("createdAt", .double).notNull()
                table.column("kind", .text).notNull()
                table.column("turnID", .text)
                table.column("isCompactionMarker", .boolean).notNull().defaults(to: false)
                table.column("isRedacted", .boolean).notNull().defaults(to: false)
                table.column("encodedRecord", .blob).notNull()
            }

            try db.create(index: "runtime_history_thread_sequence", on: RuntimeHistoryRow.databaseTableName, columns: ["threadID", "sequenceNumber"], unique: true)
            try db.create(index: "runtime_history_thread_created_at", on: RuntimeHistoryRow.databaseTableName, columns: ["threadID", "createdAt"])
            try db.create(index: "runtime_history_thread_kind", on: RuntimeHistoryRow.databaseTableName, columns: ["threadID", "kind"])
            try db.create(index: "runtime_history_thread_record_id", on: RuntimeHistoryRow.databaseTableName, columns: ["threadID", "recordID"])

            try db.create(table: RuntimeStructuredOutputRow.databaseTableName) { table in
                table.column("outputID", .text).primaryKey()
                table.column("threadID", .text)
                    .notNull()
                    .references(RuntimeThreadRow.databaseTableName, onDelete: .cascade)
                table.column("formatName", .text).notNull()
                table.column("committedAt", .double).notNull()
                table.column("encodedRecord", .blob).notNull()
            }

            try db.create(index: "runtime_structured_outputs_thread_committed_at", on: RuntimeStructuredOutputRow.databaseTableName, columns: ["threadID", "committedAt"])
            try db.create(index: "runtime_structured_outputs_format_name", on: RuntimeStructuredOutputRow.databaseTableName, columns: ["formatName"])

            try db.create(table: RuntimeContextStateRow.databaseTableName) { table in
                table.column("threadID", .text)
                    .primaryKey()
                    .references(RuntimeThreadRow.databaseTableName, onDelete: .cascade)
                table.column("generation", .integer).notNull()
                table.column("encodedState", .blob).notNull()
            }

            try db.execute(sql: "PRAGMA user_version = \(currentStoreSchemaVersion)")
        }

        migrator.registerMigration("runtime_store_v2_compaction_state") { db in
            let historyColumns = try db.columns(in: RuntimeHistoryRow.databaseTableName).map(\.name)
            if !historyColumns.contains("isCompactionMarker") {
                try db.alter(table: RuntimeHistoryRow.databaseTableName) { table in
                    table.add(column: "isCompactionMarker", .boolean).notNull().defaults(to: false)
                }
            }

            if try !db.tableExists(RuntimeContextStateRow.databaseTableName) {
                try db.create(table: RuntimeContextStateRow.databaseTableName) { table in
                    table.column("threadID", .text)
                        .primaryKey()
                        .references(RuntimeThreadRow.databaseTableName, onDelete: .cascade)
                    table.column("generation", .integer).notNull()
                    table.column("encodedState", .blob).notNull()
                }
            }

            try db.execute(sql: "PRAGMA user_version = \(currentStoreSchemaVersion)")
        }

        return migrator
    }
}
