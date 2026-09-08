import Foundation
import CodexKit
import GRDB

struct SQLiteThreadActivationMetrics: Equatable, Sendable {
    let fetchedHistoryRowCount: Int
    let decodedHistoryRowCount: Int
    let decodedHistoryByteCount: Int
    let usedPersistedContextState: Bool
}

public actor SQLiteRuntimeStateStore: RuntimeStateStoring, RuntimeStateInspecting, AgentRuntimeQueryableStore {
    // v2 is the last released SQLite runtime schema. All current work ships as v3.
    static let currentStoreSchemaVersion = 3

    let url: URL
    let legacyStateURL: URL?
    let logger: AgentLogger
    let attachmentStore: RuntimeAttachmentStore
    let dbQueue: DatabaseQueue
    let migrator: DatabaseMigrator
    var isPrepared = false
    var preparationTask: RuntimeStoreTask<Void>?
    var preparationGeneration: UInt64 = 0
    var decodedHistoryBodyCount = 0
    var latestActivationMetrics: SQLiteThreadActivationMetrics?
    var attachmentMaintenanceTask: Task<Void, Never>?

    var persistence: SQLiteRuntimeStorePersistence {
        SQLiteRuntimeStorePersistence(attachmentStore: attachmentStore)
    }

    var queries: SQLiteRuntimeStoreQueries {
        SQLiteRuntimeStoreQueries(attachmentStore: attachmentStore)
    }

    package init(
        url: URL,
        importingLegacyStateFrom legacyStateURL: URL? = nil,
        logging: AgentLoggingConfiguration = .disabled
    ) throws {
        self.url = url
        self.logger = AgentLogger(configuration: logging)
        let fileManager = FileManager.default
        self.legacyStateURL = legacyStateURL ?? Self.defaultLegacyImportURL(for: url)
        let sidecarURL = RuntimeAttachmentStore.sidecarDirectoryURL(for: url)
        let legacySidecarURL = RuntimeAttachmentStore.legacySidecarDirectoryURL(for: url)
        self.attachmentStore = RuntimeAttachmentStore(
            rootURL: sidecarURL.appendingPathComponent("attachments", isDirectory: true),
            legacyReadRootURLs: [
                legacySidecarURL.appendingPathComponent("attachments", isDirectory: true),
            ]
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
        migrator = SQLiteRuntimeStoreSchema(
            currentStoreSchemaVersion: Self.currentStoreSchemaVersion,
            attachmentStore: attachmentStore
        )
            .makeMigrator()
    }

    public func prepare() async throws -> AgentStoreMetadata {
        try await ensurePrepared()
        scheduleAttachmentMaintenance()
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

        try await RuntimeStoreMutationCoordinator.shared.perform(
            for: attachmentStore.rootURL
        ) {
            try await self.saveStateWithoutCoordination(state)
        }
    }

    func saveStateWithoutCoordination(_ state: StoredRuntimeState) async throws {
        try AgentHistoryWriteValidator.validateSnapshot(state)
        let normalized = state.normalized()
        var attachmentBatch = try attachmentStore.stageAttachments(in: normalized)
        do {
            try attachmentStore.promote(&attachmentBatch)
        } catch {
            try? await removeUnreferencedPromotedAttachments(
                attachmentBatch.newlyPromotedStorageKeys
            )
            throw error
        }
        let persistence = SQLiteRuntimeStorePersistence(
            attachmentStore: attachmentStore,
            preparedAttachments: attachmentBatch.preparedAttachments
        )
        let historyRecordCount = normalized.historyByThread.values.reduce(0) {
            AgentCounter.saturatingAdd($0, $1.count)
        }
        logger.info(
            .persistence,
            "Saving SQLite runtime state snapshot.",
            metadata: [
                "url": url.path,
                "threads": "\(normalized.threads.count)",
                "history_records": "\(historyRecordCount)"
            ]
        )
        do {
            try await dbQueue.write { db in
                try persistence.replaceDatabaseContents(
                    with: normalized,
                    in: db
                )
            }
        } catch {
            try? await removeUnreferencedPromotedAttachments(
                attachmentBatch.newlyPromotedStorageKeys
            )
            throw error
        }
        do {
            try attachmentStore.complete(attachmentBatch)
            try await settleAttachmentCleanup()
        } catch {
            logger.warning(
                .persistence,
                "SQLite state committed; deferred attachment cleanup will retry on a future mutation or preparation.",
                metadata: ["error": error.localizedDescription]
            )
        }
    }

    public func loadThreadActivationState(
        id: String,
        policy: AgentThreadActivationPolicy
    ) async throws -> AgentThreadActivationState {
        try await ensurePrepared()
        let persistence = self.persistence
        let historyRecordLimit = min(
            max(0, policy.maximumHistoryRecordCount),
            AgentStoreLimits.maximumActivationHistoryRecordCount
        )

        let loaded = try await dbQueue.read { db in
            var payloadByteCount = 0
            guard let threadRow = try RuntimeThreadRow.fetchOne(db, key: id) else {
                throw AgentRuntimeError.threadNotFound(id)
            }

            try AgentStoreLimitValidator.accumulateMaterializedPayload(
                threadRow.encodedThread,
                name: "thread activation",
                total: &payloadByteCount
            )
            let thread = try persistence.decodeThread(from: threadRow)
            let summary: AgentThreadSummary
            if let summaryRow = try RuntimeSummaryRow.fetchOne(db, key: id) {
                try AgentStoreLimitValidator.accumulateMaterializedPayload(
                    summaryRow.encodedSummary,
                    name: "thread activation",
                    total: &payloadByteCount
                )
                summary = try persistence.decodeSummary(from: summaryRow)
            } else {
                summary = StoredRuntimeState(threads: [thread]).threadSummaryFallback(for: thread)
            }

            let nextHistorySequence = try RuntimeNextHistorySequenceQuery(threadID: id)
                .execute(in: db)

            if let contextRow = try RuntimeContextStateRow.fetchOne(db, key: id) {
                try AgentStoreLimitValidator.accumulateMaterializedPayload(
                    contextRow.encodedState,
                    name: "thread activation",
                    total: &payloadByteCount
                )
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

            let candidateLimit = historyRecordLimit * 2 + 1
            let candidates = try SQLRequest<RuntimeHistoryWindowRow>(
                sql: """
                WITH recent AS (
                    SELECT storageID, relationshipKey
                    FROM \(RuntimeHistoryRow.databaseTableName)
                    WHERE threadID = ?
                    ORDER BY sequenceNumber DESC
                    LIMIT ?
                )
                SELECT history.storageID,
                       history.sequenceNumber,
                       history.relationshipKey
                FROM \(RuntimeHistoryRow.databaseTableName) AS history
                WHERE history.threadID = ?
                  AND (
                    history.storageID IN (SELECT storageID FROM recent)
                    OR history.relationshipKey IN (
                        SELECT relationshipKey FROM recent
                        WHERE relationshipKey IS NOT NULL
                    )
                  )
                ORDER BY history.sequenceNumber DESC
                LIMIT ?
                """,
                arguments: [id, historyRecordLimit, id, candidateLimit]
            ).fetchAll(db)
            guard candidates.count < candidateLimit else {
                throw AgentStoreError.invalidInput(
                    "stored activation relationships exceed their bounded cardinality"
                )
            }
            let selectedKeys = try AgentThreadContextWindow.completeHistoryStorageKeys(
                from: candidates.map {
                    .init(
                        storageKey: $0.storageID,
                        sequenceNumber: $0.sequenceNumber,
                        relationshipKey: $0.relationshipKey
                    )
                },
                limit: historyRecordLimit
            )
            let rowRequest = RuntimeHistoryRow
                .filter(selectedKeys.contains(Column("storageID")))
                .order(Column("sequenceNumber").asc)
            let rows = try boundedRuntimeRows(
                rowRequest.fetchCursor(db),
                payload: \.encodedRecord,
                name: "thread activation",
                payloadByteCount: &payloadByteCount
            )
            let records = try rows.map(persistence.decodeHistoryRecord)
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
                    fetchedHistoryRowCount: candidates.count,
                    decodedHistoryRowCount: rows.count,
                    decodedHistoryByteCount: rows.reduce(0) {
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
                arguments: [threadID, AgentStoreLimitValidator.boundedLimit(limit)]
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
        try AgentStoreLimitValidator.validate(operations)

        try await RuntimeStoreMutationCoordinator.shared.perform(
            for: attachmentStore.rootURL
        ) {
            try await self.applyWithoutCoordination(operations)
        }
        scheduleAttachmentMaintenance()
    }

    private func applyWithoutCoordination(_ operations: [AgentStoreWriteOperation]) async throws {
        var attachmentBatch = try attachmentStore.stageAttachments(in: operations)
        do {
            try attachmentStore.promote(&attachmentBatch)
        } catch {
            try? await removeUnreferencedPromotedAttachments(
                attachmentBatch.newlyPromotedStorageKeys
            )
            throw error
        }
        let persistence = SQLiteRuntimeStorePersistence(
            attachmentStore: attachmentStore,
            preparedAttachments: attachmentBatch.preparedAttachments
        )
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
        do {
            try await dbQueue.write { db in
                try persistence.apply(operations, in: db)
            }
        } catch {
            try? await removeUnreferencedPromotedAttachments(
                attachmentBatch.newlyPromotedStorageKeys
            )
            throw error
        }
        do {
            try attachmentStore.complete(attachmentBatch)
            _ = try await settleAttachmentCleanupBatch()
        } catch {
            logger.warning(
                .persistence,
                "SQLite operations committed; deferred attachment cleanup will retry on a future mutation or preparation.",
                metadata: ["error": error.localizedDescription]
            )
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
        try AgentStoreLimitValidator.validateHistoryPage(query)
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
        try AgentStoreLimitValidator.validate(query)

        if let historyQuery = query as? HistoryItemsQuery {
            return try castAgentQueryResult(
                await executeHistoryQuery(historyQuery),
                to: Query.Result.self
            )
        }
        if let threadQuery = query as? ThreadMetadataQuery {
            return try castAgentQueryResult(
                await executeThreadQuery(threadQuery),
                to: Query.Result.self
            )
        }
        if let pendingQuery = query as? PendingStateQuery {
            return try castAgentQueryResult(
                await executePendingStateQuery(pendingQuery),
                to: Query.Result.self
            )
        }
        if let structuredQuery = query as? StructuredOutputQuery {
            return try castAgentQueryResult(
                await executeStructuredOutputQuery(structuredQuery),
                to: Query.Result.self
            )
        }
        if let snapshotQuery = query as? ThreadSnapshotQuery {
            return try castAgentQueryResult(
                await executeThreadSnapshotQuery(snapshotQuery),
                to: Query.Result.self
            )
        }
        if let contextQuery = query as? ThreadContextStateQuery {
            return try castAgentQueryResult(
                await executeThreadContextStateQuery(contextQuery),
                to: Query.Result.self
            )
        }

        throw AgentStoreError.queryNotSupported(String(describing: Query.self))
    }

}

extension SQLiteRuntimeStateStore: StoreMigrationIdentifying, StoreMigrationCoordinating {
    package nonisolated var storeMigrationIdentity: StoreMigrationIdentity {
        StoreMigrationIdentity(kind: "runtime", url: url)
    }

    package nonisolated var migrationCoordinationRootURL: URL {
        attachmentStore.rootURL
    }
}
