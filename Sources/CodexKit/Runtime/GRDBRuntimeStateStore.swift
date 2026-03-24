import Foundation
import GRDB

public actor GRDBRuntimeStateStore: RuntimeStateStoring, RuntimeStateInspecting, AgentRuntimeQueryableStore {
    static let currentStoreSchemaVersion = 2

    let url: URL
    let legacyStateURL: URL?
    let attachmentStore: RuntimeAttachmentStore
    let databaseExistedAtInitialization: Bool
    let dbQueue: DatabaseQueue
    let migrator: DatabaseMigrator
    var isPrepared = false

    public init(
        url: URL,
        importingLegacyStateFrom legacyStateURL: URL? = nil
    ) throws {
        self.url = url
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
        migrator = Self.makeMigrator()
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

        return try await dbQueue.read { db in
            let threadRows = try RuntimeThreadRow.fetchAll(db)
            let summaryRows = try RuntimeSummaryRow.fetchAll(db)
            let historyRows = try RuntimeHistoryRow.fetchAll(db)
            let contextRows = try RuntimeContextStateRow.fetchAll(db)

            let threads = try threadRows.map { try Self.decodeThread(from: $0) }
            let summariesByThread = try Dictionary(
                uniqueKeysWithValues: summaryRows.map { row in
                    (row.threadID, try Self.decodeSummary(from: row))
                }
            )
            let decodedHistoryRows = try historyRows.map {
                try Self.decodeHistoryRecord(from: $0, attachmentStore: attachmentStore)
            }
            let historyByThread = Dictionary(grouping: decodedHistoryRows, by: { $0.item.threadID })
            let contextStateByThread = try Dictionary(
                uniqueKeysWithValues: contextRows.map { row in
                    (row.threadID, try Self.decodeContextState(from: row))
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
        try attachmentStore.reset()
        try await dbQueue.write { db in
            try Self.replaceDatabaseContents(
                with: normalized,
                in: db,
                attachmentStore: attachmentStore
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

        try await dbQueue.write { db in
            var partialState = try Self.loadPartialState(
                for: affectedThreadIDs,
                from: db,
                attachmentStore: attachmentStore
            )
            partialState = try partialState.applying(operations)

            for threadID in affectedThreadIDs {
                try Self.deletePersistedThread(threadID, in: db)
                try attachmentStore.removeThread(threadID)
            }

            try Self.persistThreads(
                ids: affectedThreadIDs,
                from: partialState,
                in: db,
                attachmentStore: attachmentStore
            )
        }
    }

    public func fetchThreadSummary(id: String) async throws -> AgentThreadSummary {
        try await ensurePrepared()

        return try await dbQueue.read { db in
            guard let threadRow = try RuntimeThreadRow.fetchOne(db, key: id) else {
                throw AgentRuntimeError.threadNotFound(id)
            }
            if let summaryRow = try RuntimeSummaryRow.fetchOne(db, key: id) {
                return try Self.decodeSummary(from: summaryRow)
            }
            let thread = try Self.decodeThread(from: threadRow)
            return StoredRuntimeState(threads: [thread]).threadSummaryFallback(for: thread)
        }
    }

    public func fetchThreadHistory(
        id: String,
        query: AgentHistoryQuery
    ) async throws -> AgentThreadHistoryPage {
        try await ensurePrepared()

        return try await dbQueue.read { db in
            guard try RuntimeThreadRow.fetchOne(db, key: id) != nil else {
                throw AgentRuntimeError.threadNotFound(id)
            }

            return try Self.fetchHistoryPage(
                threadID: id,
                query: query,
                in: db,
                attachmentStore: attachmentStore
            )
        }
    }

    public func fetchLatestStructuredOutputMetadata(id: String) async throws -> AgentStructuredOutputMetadata? {
        let summary = try await fetchThreadSummary(id: id)
        return summary.latestStructuredOutputMetadata
    }

    public func fetchThreadContextState(id: String) async throws -> AgentThreadContextState? {
        try await ensurePrepared()
        return try await dbQueue.read { db in
            guard try RuntimeThreadRow.fetchOne(db, key: id) != nil else {
                throw AgentRuntimeError.threadNotFound(id)
            }
            guard let row = try RuntimeContextStateRow.fetchOne(db, key: id) else {
                return nil
            }
            return try Self.decodeContextState(from: row)
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

        let version = try await readUserVersion()
        guard version <= Self.currentStoreSchemaVersion else {
            throw AgentStoreError.migrationFailed(
                "Unsupported future GRDB runtime store schema version \(version)."
            )
        }

        try migrator.migrate(dbQueue)
        if try await shouldImportLegacyState() {
            try await importLegacyState()
        }
        isPrepared = true
    }
}
