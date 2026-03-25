import Foundation
import GRDB

extension GRDBRuntimeStateStore {
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

struct GRDBRuntimeStorePersistence: Sendable {
    let attachmentStore: RuntimeAttachmentStore

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
        RuntimeContextStateRow(
            threadID: state.threadID,
            generation: state.generation,
            encodedState: try JSONEncoder().encode(state)
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
        try JSONDecoder().decode(AgentThreadContextState.self, from: row.encodedState)
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

struct GRDBRuntimeStoreSchema: Sendable {
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
