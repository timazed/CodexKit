import Foundation
import GRDB

struct SQLiteThreadActivationMetrics: Equatable, Sendable {
    let fetchedHistoryRowCount: Int
    let decodedHistoryRowCount: Int
    let decodedHistoryByteCount: Int
    let usedPersistedContextState: Bool
}

public actor SQLiteRuntimeStateStore: RuntimeStateStoring, RuntimeStateInspecting, AgentRuntimeQueryableStore {
    static let currentStoreSchemaVersion = 2

    let url: URL
    let legacyStateURL: URL?
    let logger: AgentLogger
    let attachmentStore: RuntimeAttachmentStore
    let databaseExistedAtInitialization: Bool
    let dbQueue: DatabaseQueue
    let migrator: DatabaseMigrator
    var isPrepared = false
    var decodedHistoryBodyCount = 0
    var latestActivationMetrics: SQLiteThreadActivationMetrics?

    var persistence: SQLiteRuntimeStorePersistence {
        SQLiteRuntimeStorePersistence(attachmentStore: attachmentStore)
    }

    var queries: SQLiteRuntimeStoreQueries {
        SQLiteRuntimeStoreQueries(attachmentStore: attachmentStore)
    }

    public init(
        url: URL,
        importingLegacyStateFrom legacyStateURL: URL? = nil,
        logging: AgentLoggingConfiguration = .disabled
    ) throws {
        self.url = url
        self.logger = AgentLogger(configuration: logging)
        let fileManager = FileManager.default
        let basename = url.deletingPathExtension().lastPathComponent
        self.databaseExistedAtInitialization = fileManager.fileExists(atPath: url.path)
        self.legacyStateURL = legacyStateURL ?? Self.defaultLegacyImportURL(for: url)
        self.attachmentStore = RuntimeAttachmentStore(
            rootURL: url.deletingLastPathComponent()
                .appendingPathComponent("\(basename).codexkit-state", isDirectory: true)
                .appendingPathComponent("attachments", isDirectory: true)
        )

        let directory = url.deletingLastPathComponent()
        if !directory.path.isEmpty {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }

        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.busyMode = .timeout(5)
        configuration.label = "CodexKit.SQLiteRuntimeStateStore"
        dbQueue = try DatabaseQueue(path: url.path, configuration: configuration)
        migrator = SQLiteRuntimeStoreSchema(currentStoreSchemaVersion: Self.currentStoreSchemaVersion)
            .makeMigrator()
    }

    public func prepare() async throws -> AgentStoreMetadata {
        try await ensurePrepared()
        return try await readMetadata()
    }

    public func readMetadata() async throws -> AgentStoreMetadata {
        try await ensurePrepared()
        let storeSchemaVersion = try await readUserVersion()

        return AgentStoreMetadata(
            logicalSchemaVersion: .v1,
            storeSchemaVersion: storeSchemaVersion,
            capabilities: AgentStoreCapabilities(
                supportsPushdownQueries: true,
                supportsCrossThreadQueries: true,
                supportsSorting: true,
                supportsFiltering: true,
                supportsMigrations: true,
                supportsLazyThreadActivation: true
            ),
            storeKind: "SQLiteRuntimeStateStore"
        )
    }

    public func loadState() async throws -> StoredRuntimeState {
        try await ensurePrepared()
        let persistence = self.persistence
        logger.debug(.persistence, "Loading SQLite runtime state.", metadata: ["url": url.path])

        let loaded = try await dbQueue.read { db in
            let threadRows = try RuntimeThreadRow.fetchAll(db)
            let summaryRows = try RuntimeSummaryRow.fetchAll(db)
            let historyRows = try RuntimeHistoryRow.fetchAll(db)
            let contextRows = try RuntimeContextStateRow.fetchAll(db)

            let threads = try threadRows.map { try persistence.decodeThread(from: $0) }
            let summariesByThread = try Dictionary(
                uniqueKeysWithValues: summaryRows.map { row in
                    (row.threadID, try persistence.decodeSummary(from: row))
                }
            )
            let decodedHistoryRows = try historyRows.map {
                try persistence.decodeHistoryRecord(from: $0)
            }
            let historyByThread = Dictionary(grouping: decodedHistoryRows, by: { $0.item.threadID })
            let contextStateByThread = try Dictionary(
                uniqueKeysWithValues: contextRows.map { row in
                    (row.threadID, try persistence.decodeContextState(from: row))
                }
            )

            return (
                state: StoredRuntimeState(
                    threads: threads,
                    historyByThread: historyByThread,
                    summariesByThread: summariesByThread,
                    contextStateByThread: contextStateByThread
                ),
                decodedHistoryBodyCount: historyRows.count
            )
        }
        decodedHistoryBodyCount += loaded.decodedHistoryBodyCount
        let loadedState = loaded.state
        logger.debug(
            .persistence,
            "Loaded SQLite runtime state.",
            metadata: [
                "url": url.path,
                "threads": "\(loadedState.threads.count)",
                "history_threads": "\(loadedState.historyByThread.count)",
                "context_states": "\(loadedState.contextStateByThread.count)"
            ]
        )
        return loadedState
    }

    public func saveState(_ state: StoredRuntimeState) async throws {
        try await ensurePrepared()

        let normalized = state.normalized()
        let persistence = self.persistence
        logger.info(
            .persistence,
            "Saving SQLite runtime state snapshot.",
            metadata: [
                "url": url.path,
                "threads": "\(normalized.threads.count)",
                "history_records": "\(normalized.historyByThread.values.reduce(0) { $0 + $1.count })"
            ]
        )
        try attachmentStore.reset()
        try await dbQueue.write { db in
            try persistence.replaceDatabaseContents(
                with: normalized,
                in: db
            )
        }
    }

    public func loadThreadActivationState(
        id: String,
        policy: AgentThreadActivationPolicy
    ) async throws -> AgentThreadActivationState {
        try await ensurePrepared()
        let persistence = self.persistence
        let historyRecordLimit = max(0, policy.maximumHistoryRecordCount)
        let historyQueryLimit = historyRecordLimit == Int.max
            ? Int.max
            : historyRecordLimit + 1

        let loaded = try await dbQueue.read { db in
            guard let threadRow = try RuntimeThreadRow.fetchOne(db, key: id) else {
                throw AgentRuntimeError.threadNotFound(id)
            }

            let thread = try persistence.decodeThread(from: threadRow)
            let summary: AgentThreadSummary
            if let summaryRow = try RuntimeSummaryRow.fetchOne(db, key: id) {
                summary = try persistence.decodeSummary(from: summaryRow)
            } else {
                summary = StoredRuntimeState(threads: [thread]).threadSummaryFallback(for: thread)
            }

            let nextHistorySequence = try RuntimeNextHistorySequenceQuery(threadID: id)
                .execute(in: db)

            if let contextRow = try RuntimeContextStateRow.fetchOne(db, key: id) {
                let persistedContextState = try persistence.decodeContextState(from: contextRow)
                let effectiveMessages = AgentThreadContextWindow.boundedMessages(
                    persistedContextState.effectiveMessages,
                    policy: policy,
                    requireClosedTurns: true
                )
                let contextState = AgentThreadContextState(
                    threadID: id,
                    effectiveMessages: effectiveMessages,
                    providerContext: effectiveMessages == persistedContextState.effectiveMessages
                        ? persistedContextState.providerContext
                        : nil,
                    generation: persistedContextState.generation,
                    lastCompactedAt: persistedContextState.lastCompactedAt,
                    lastCompactionReason: persistedContextState.lastCompactionReason,
                    latestMarkerID: persistedContextState.latestMarkerID
                )
                return (
                    state: AgentThreadActivationState(
                        thread: thread,
                        summary: summary,
                        contextState: contextState,
                        nextHistorySequence: nextHistorySequence,
                        effectiveMessages: effectiveMessages
                    ),
                    metrics: SQLiteThreadActivationMetrics(
                        fetchedHistoryRowCount: 0,
                        decodedHistoryRowCount: 0,
                        decodedHistoryByteCount: 0,
                        usedPersistedContextState: true
                    )
                )
            }

            guard historyRecordLimit > 0 else {
                return (
                    state: AgentThreadActivationState(
                        thread: thread,
                        summary: summary,
                        contextState: nil,
                        nextHistorySequence: nextHistorySequence,
                        effectiveMessages: []
                    ),
                    metrics: SQLiteThreadActivationMetrics(
                        fetchedHistoryRowCount: 0,
                        decodedHistoryRowCount: 0,
                        decodedHistoryByteCount: 0,
                        usedPersistedContextState: false
                    )
                )
            }

            // Fetch one extra row so a cut relationship at the leading edge can be
            // discarded rather than exposed as a partial conversational turn.
            let rows = try RuntimeHistoryRowsRequest(
                sql: """
                SELECT * FROM \(RuntimeHistoryRow.databaseTableName)
                WHERE threadID = ?
                ORDER BY sequenceNumber DESC
                LIMIT ?
                """,
                arguments: [id, historyQueryLimit]
            ).execute(in: db)
            let boundedRows = Array(rows.prefix(historyRecordLimit)).reversed()
            let records = try boundedRows.map(persistence.decodeHistoryRecord)
            let messages = AgentThreadContextWindow.reconstructedMessages(from: records)
            let effectiveMessages = AgentThreadContextWindow.boundedMessages(
                messages,
                policy: policy,
                requireClosedTurns: true
            )

            return (
                state: AgentThreadActivationState(
                    thread: thread,
                    summary: summary,
                    contextState: nil,
                    nextHistorySequence: nextHistorySequence,
                    effectiveMessages: effectiveMessages
                ),
                metrics: SQLiteThreadActivationMetrics(
                    fetchedHistoryRowCount: rows.count,
                    decodedHistoryRowCount: boundedRows.count,
                    decodedHistoryByteCount: boundedRows.reduce(0) {
                        $0 + $1.encodedRecord.count
                    },
                    usedPersistedContextState: false
                )
            )
        }
        latestActivationMetrics = loaded.metrics
        decodedHistoryBodyCount += loaded.metrics.decodedHistoryRowCount
        return loaded.state
    }

    func resetActivationDiagnostics() {
        decodedHistoryBodyCount = 0
        latestActivationMetrics = nil
    }

    func activationDiagnostics() -> (
        decodedHistoryBodyCount: Int,
        latestActivation: SQLiteThreadActivationMetrics?
    ) {
        (decodedHistoryBodyCount, latestActivationMetrics)
    }

    func activationHistoryQueryPlan(
        threadID: String,
        limit: Int
    ) async throws -> [String] {
        try await ensurePrepared()
        return try await dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                EXPLAIN QUERY PLAN
                SELECT * FROM \(RuntimeHistoryRow.databaseTableName)
                WHERE threadID = ?
                ORDER BY sequenceNumber DESC
                LIMIT ?
                """,
                arguments: [threadID, max(1, limit)]
            )
            return rows.compactMap { row in
                let detail: String? = row["detail"]
                return detail
            }
        }
    }

    public func apply(_ operations: [AgentStoreWriteOperation]) async throws {
        try await ensurePrepared()
        guard !operations.isEmpty else {
            return
        }

        let persistence = self.persistence
        logger.debug(
            .persistence,
            "Applying SQLite runtime state operations.",
            metadata: [
                "url": url.path,
                "operation_count": "\(operations.count)",
                "affected_threads": "\(Set(operations.map(\.affectedThreadID)).count)",
                "operation_types": operationTypeSummary(for: operations)
            ]
        )
        try await dbQueue.write { db in
            if operations.contains(where: { operation in
                if case .redactHistoryItems = operation { return true }
                return false
            }) {
                let affectedThreadIDs = Set(operations.map(\.affectedThreadID))
                var partialState = try persistence.loadPartialState(
                    for: affectedThreadIDs,
                    from: db
                )
                partialState = try partialState.applying(operations)
                for threadID in affectedThreadIDs {
                    try persistence.deletePersistedThread(threadID, in: db)
                    try attachmentStore.removeThread(threadID)
                }
                try persistence.persistThreads(
                    ids: affectedThreadIDs,
                    from: partialState,
                    in: db
                )
            } else {
                try persistence.apply(operations, in: db)
            }
        }
    }

    public func fetchThreadSummary(id: String) async throws -> AgentThreadSummary {
        try await ensurePrepared()
        let persistence = self.persistence

        return try await dbQueue.read { db in
            guard let threadRow = try RuntimeThreadRow.fetchOne(db, key: id) else {
                throw AgentRuntimeError.threadNotFound(id)
            }
            if let summaryRow = try RuntimeSummaryRow.fetchOne(db, key: id) {
                return try persistence.decodeSummary(from: summaryRow)
            }
            let thread = try persistence.decodeThread(from: threadRow)
            return StoredRuntimeState(threads: [thread]).threadSummaryFallback(for: thread)
        }
    }

    public func fetchThreadHistory(
        id: String,
        query: AgentHistoryQuery
    ) async throws -> AgentThreadHistoryPage {
        try await ensurePrepared()
        let queries = self.queries

        return try await dbQueue.read { db in
            guard try RuntimeThreadRow.fetchOne(db, key: id) != nil else {
                throw AgentRuntimeError.threadNotFound(id)
            }

            return try queries.fetchHistoryPage(
                threadID: id,
                query: query,
                in: db
            )
        }
    }

    public func fetchLatestStructuredOutputMetadata(id: String) async throws -> AgentStructuredOutputMetadata? {
        let summary = try await fetchThreadSummary(id: id)
        return summary.latestStructuredOutputMetadata
    }

    public func fetchThreadContextState(id: String) async throws -> AgentThreadContextState? {
        try await ensurePrepared()
        let persistence = self.persistence
        return try await dbQueue.read { db in
            guard try RuntimeThreadRow.fetchOne(db, key: id) != nil else {
                throw AgentRuntimeError.threadNotFound(id)
            }
            guard let row = try RuntimeContextStateRow.fetchOne(db, key: id) else {
                return nil
            }
            return try persistence.decodeContextState(from: row)
        }
    }

    public func execute<Query: AgentQuerySpec>(_ query: Query) async throws -> Query.Result {
        try await ensurePrepared()

        if let historyQuery = query as? HistoryItemsQuery {
            return try await executeHistoryQuery(historyQuery) as! Query.Result
        }
        if let threadQuery = query as? ThreadMetadataQuery {
            return try await executeThreadQuery(threadQuery) as! Query.Result
        }
        if let pendingQuery = query as? PendingStateQuery {
            return try await executePendingStateQuery(pendingQuery) as! Query.Result
        }
        if let structuredQuery = query as? StructuredOutputQuery {
            return try await executeStructuredOutputQuery(structuredQuery) as! Query.Result
        }
        if let snapshotQuery = query as? ThreadSnapshotQuery {
            return try await executeThreadSnapshotQuery(snapshotQuery) as! Query.Result
        }
        if let contextQuery = query as? ThreadContextStateQuery {
            return try await executeThreadContextStateQuery(contextQuery) as! Query.Result
        }

        let state = try await loadState()
        return try query.execute(in: state)
    }

    func ensurePrepared() async throws {
        if isPrepared {
            return
        }

        logger.info(.persistence, "Preparing SQLite runtime state store.", metadata: ["url": url.path])
        let version = try await readUserVersion()
        guard version <= Self.currentStoreSchemaVersion else {
            throw AgentStoreError.migrationFailed(
                "Unsupported future SQLite runtime store schema version \(version)."
            )
        }

        try migrator.migrate(dbQueue)
        if try await shouldImportLegacyState() {
            logger.info(
                .persistence,
                "Importing legacy file runtime state into SQLite store.",
                metadata: ["legacy_url": legacyStateURL?.path ?? ""]
            )
            try await importLegacyState()
        }
        isPrepared = true
        logger.info(.persistence, "SQLite runtime state store prepared.", metadata: ["url": url.path])
    }

    private func operationTypeSummary(
        for operations: [AgentStoreWriteOperation]
    ) -> String {
        let counts = Dictionary(operations.map(operationTypeLabel(for:)), uniquingKeysWith: +)
        return counts
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ",")
    }

    private func operationTypeLabel(
        for operation: AgentStoreWriteOperation
    ) -> (String, Int) {
        switch operation {
        case .upsertThread:
            return ("upsert_thread", 1)
        case .upsertSummary:
            return ("upsert_summary", 1)
        case .appendHistoryItems:
            return ("append_history", 1)
        case .setPendingState:
            return ("set_pending_state", 1)
        case .setPartialStructuredSnapshot:
            return ("set_partial_snapshot", 1)
        case .upsertToolSession:
            return ("upsert_tool_session", 1)
        case .redactHistoryItems:
            return ("redact_history", 1)
        case .deleteThread:
            return ("delete_thread", 1)
        case .upsertThreadContextState:
            return ("upsert_context_state", 1)
        case .appendCompactionMarker:
            return ("append_compaction_marker", 1)
        case .deleteThreadContextState:
            return ("delete_context_state", 1)
        }
    }
}
