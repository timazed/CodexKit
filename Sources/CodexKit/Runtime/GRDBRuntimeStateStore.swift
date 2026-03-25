import Foundation
import GRDB

public actor GRDBRuntimeStateStore: RuntimeStateStoring, RuntimeStateInspecting, AgentRuntimeQueryableStore {
    static let currentStoreSchemaVersion = 2

    let url: URL
    let legacyStateURL: URL?
    let logger: AgentLogger
    let attachmentStore: RuntimeAttachmentStore
    let databaseExistedAtInitialization: Bool
    let dbQueue: DatabaseQueue
    let migrator: DatabaseMigrator
    var isPrepared = false

    var persistence: GRDBRuntimeStorePersistence {
        GRDBRuntimeStorePersistence(attachmentStore: attachmentStore)
    }

    var queries: GRDBRuntimeStoreQueries {
        GRDBRuntimeStoreQueries(attachmentStore: attachmentStore)
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
        configuration.label = "CodexKit.GRDBRuntimeStateStore"
        dbQueue = try DatabaseQueue(path: url.path, configuration: configuration)
        migrator = GRDBRuntimeStoreSchema(currentStoreSchemaVersion: Self.currentStoreSchemaVersion)
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
                supportsMigrations: true
            ),
            storeKind: "GRDBRuntimeStateStore"
        )
    }

    public func loadState() async throws -> StoredRuntimeState {
        try await ensurePrepared()
        let persistence = self.persistence
        logger.debug(.persistence, "Loading GRDB runtime state.", metadata: ["url": url.path])

        return try await dbQueue.read { db in
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

            return StoredRuntimeState(
                threads: threads,
                historyByThread: historyByThread,
                summariesByThread: summariesByThread,
                contextStateByThread: contextStateByThread
            )
        }
    }

    public func saveState(_ state: StoredRuntimeState) async throws {
        try await ensurePrepared()

        let normalized = state.normalized()
        let persistence = self.persistence
        logger.info(
            .persistence,
            "Saving GRDB runtime state snapshot.",
            metadata: [
                "url": url.path,
                "threads": "\(normalized.threads.count)"
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

    public func apply(_ operations: [AgentStoreWriteOperation]) async throws {
        try await ensurePrepared()
        guard !operations.isEmpty else {
            return
        }

        let affectedThreadIDs = Set(operations.map(\.affectedThreadID))
        guard !affectedThreadIDs.isEmpty else {
            return
        }

        let persistence = self.persistence
        logger.debug(
            .persistence,
            "Applying GRDB runtime state operations.",
            metadata: [
                "url": url.path,
                "operation_count": "\(operations.count)",
                "affected_threads": "\(affectedThreadIDs.count)"
            ]
        )
        try await dbQueue.write { db in
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

        logger.info(.persistence, "Preparing GRDB runtime state store.", metadata: ["url": url.path])
        let version = try await readUserVersion()
        guard version <= Self.currentStoreSchemaVersion else {
            throw AgentStoreError.migrationFailed(
                "Unsupported future GRDB runtime store schema version \(version)."
            )
        }

        try migrator.migrate(dbQueue)
        if try await shouldImportLegacyState() {
            logger.info(
                .persistence,
                "Importing legacy file runtime state into GRDB store.",
                metadata: ["legacy_url": legacyStateURL?.path ?? ""]
            )
            try await importLegacyState()
        }
        isPrepared = true
        logger.info(.persistence, "GRDB runtime state store prepared.", metadata: ["url": url.path])
    }
}
