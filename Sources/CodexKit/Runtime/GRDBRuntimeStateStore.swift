import Foundation
import GRDB

public actor GRDBRuntimeStateStore: RuntimeStateStoring, RuntimeStateInspecting, AgentRuntimeQueryableStore {
    private static let currentStoreSchemaVersion = 1

    private let url: URL
    private let legacyStateURL: URL?
    private let attachmentStore: RuntimeAttachmentStore
    private let databaseExistedAtInitialization: Bool
    private let dbQueue: DatabaseQueue
    private let migrator: DatabaseMigrator
    private var isPrepared = false

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

            return StoredRuntimeState(
                threads: threads,
                historyByThread: historyByThread,
                summariesByThread: summariesByThread
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

        let state = try await loadState()
        return try query.execute(in: state)
    }

    private func ensurePrepared() async throws {
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

    private func executeHistoryQuery(_ query: HistoryItemsQuery) async throws -> AgentHistoryQueryResult {
        try await dbQueue.read { db in
            guard let threadRow = try RuntimeThreadRow.fetchOne(db, key: query.threadID) else {
                return AgentHistoryQueryResult(
                    threadID: query.threadID,
                    records: [],
                    nextCursor: nil,
                    previousCursor: nil,
                    hasMoreBefore: false,
                    hasMoreAfter: false
                )
            }

            let thread = try Self.decodeThread(from: threadRow)
            let history = try Self.fetchHistoryRows(
                threadID: query.threadID,
                kinds: query.kinds,
                createdAtRange: query.createdAtRange,
                turnID: query.turnID,
                includeRedacted: query.includeRedacted,
                in: db,
                attachmentStore: attachmentStore
            )

            let state = StoredRuntimeState(
                threads: [thread],
                historyByThread: [query.threadID: history]
            )
            return try state.execute(query)
        }
    }

    private func executeThreadQuery(_ query: ThreadMetadataQuery) async throws -> [AgentThread] {
        try await dbQueue.read { db in
            let rows = try RuntimeThreadRow.fetchAll(
                db,
                sql: Self.threadMetadataSQL(for: query),
                arguments: StatementArguments(Self.threadMetadataArguments(for: query))
            )
            return try rows.map { try Self.decodeThread(from: $0) }
        }
    }

    private func executePendingStateQuery(_ query: PendingStateQuery) async throws -> [AgentPendingStateRecord] {
        try await dbQueue.read { db in
            let summaries = try RuntimeSummaryRow.fetchAll(
                db,
                sql: Self.pendingStateSQL(for: query),
                arguments: StatementArguments(Self.pendingStateArguments(for: query))
            )
            let records = try summaries.compactMap { row -> AgentPendingStateRecord? in
                let summary = try Self.decodeSummary(from: row)
                guard let pendingState = summary.pendingState else {
                    return nil
                }
                return AgentPendingStateRecord(
                    threadID: summary.threadID,
                    pendingState: pendingState,
                    updatedAt: summary.updatedAt
                )
            }
            return records
        }
    }

    private func executeStructuredOutputQuery(_ query: StructuredOutputQuery) async throws -> [AgentStructuredOutputRecord] {
        try await dbQueue.read { db in
            var records = try RuntimeStructuredOutputRow.fetchAll(
                db,
                sql: Self.structuredOutputSQL(for: query),
                arguments: StatementArguments(Self.structuredOutputArguments(for: query))
            ).map { try Self.decodeStructuredOutputRecord(from: $0) }

            if query.latestOnly {
                var seen = Set<String>()
                records = records.filter { seen.insert($0.threadID).inserted }
            }

            if let limit = query.limit {
                records = Array(records.prefix(max(0, limit)))
            }
            return records
        }
    }

    private func executeThreadSnapshotQuery(_ query: ThreadSnapshotQuery) async throws -> [AgentThreadSnapshot] {
        try await dbQueue.read { db in
            let snapshots = try RuntimeSummaryRow.fetchAll(
                db,
                sql: Self.threadSnapshotSQL(for: query),
                arguments: StatementArguments(Self.threadSnapshotArguments(for: query))
            )
                .map { try Self.decodeSummary(from: $0) }
                .map(\.snapshot)
            return snapshots
        }
    }

    private static func replaceDatabaseContents(
        with normalized: StoredRuntimeState,
        in db: Database,
        attachmentStore: RuntimeAttachmentStore
    ) throws {
        let threadRows = try normalized.threads.map(Self.makeThreadRow)
        let summaryRows = try normalized.threads.compactMap { thread -> RuntimeSummaryRow? in
            guard let summary = normalized.summariesByThread[thread.id] else {
                return nil
            }
            return try Self.makeSummaryRow(from: summary)
        }
        let historyRows = try normalized.historyByThread.values
            .flatMap { $0 }
            .map { try Self.makeHistoryRow(from: $0, attachmentStore: attachmentStore) }
        let structuredOutputRows = try Self.structuredOutputRows(from: normalized.historyByThread)

        try RuntimeStructuredOutputRow.deleteAll(db)
        try RuntimeHistoryRow.deleteAll(db)
        try RuntimeSummaryRow.deleteAll(db)
        try RuntimeThreadRow.deleteAll(db)

        for row in threadRows {
            try row.insert(db)
        }
        for row in summaryRows {
            try row.insert(db)
        }
        for row in historyRows {
            try row.insert(db)
        }
        for row in structuredOutputRows {
            try row.insert(db)
        }
    }

    private func shouldImportLegacyState() async throws -> Bool {
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
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(RuntimeThreadRow.databaseTableName)") ?? 0
        }
        return threadCount == 0
    }

    private func importLegacyState() async throws {
        guard let legacyStateURL else {
            return
        }

        let legacyStore = FileRuntimeStateStore(url: legacyStateURL)
        let state = try await legacyStore.loadState().normalized()
        guard !state.threads.isEmpty || !state.historyByThread.isEmpty else {
            return
        }

        try await dbQueue.write { db in
            try attachmentStore.reset()
            try Self.replaceDatabaseContents(
                with: state,
                in: db,
                attachmentStore: attachmentStore
            )
        }
    }

    private static func loadPartialState(
        for threadIDs: Set<String>,
        from db: Database,
        attachmentStore: RuntimeAttachmentStore
    ) throws -> StoredRuntimeState {
        guard !threadIDs.isEmpty else {
            return .empty
        }

        let ids = Array(threadIDs)
        let placeholders = Self.sqlPlaceholders(count: ids.count)
        let threadRows = try RuntimeThreadRow.fetchAll(
            db,
            sql: "SELECT * FROM \(RuntimeThreadRow.databaseTableName) WHERE threadID IN \(placeholders)",
            arguments: StatementArguments(ids)
        )
        let summaryRows = try RuntimeSummaryRow.fetchAll(
            db,
            sql: "SELECT * FROM \(RuntimeSummaryRow.databaseTableName) WHERE threadID IN \(placeholders)",
            arguments: StatementArguments(ids)
        )
        let historyRows = try RuntimeHistoryRow.fetchAll(
            db,
            sql: """
            SELECT * FROM \(RuntimeHistoryRow.databaseTableName)
            WHERE threadID IN \(placeholders)
            ORDER BY threadID ASC, sequenceNumber ASC
            """,
            arguments: StatementArguments(ids)
        )

        let threads = try threadRows.map { try Self.decodeThread(from: $0) }
        let summaries = try Dictionary<String, AgentThreadSummary>(
            uniqueKeysWithValues: summaryRows.map { ($0.threadID, try Self.decodeSummary(from: $0)) }
        )
        let decodedHistoryRows = try historyRows.map {
            try Self.decodeHistoryRecord(from: $0, attachmentStore: attachmentStore)
        }
        let history = Dictionary(grouping: decodedHistoryRows, by: { $0.item.threadID })
        let nextSequence = history.mapValues { ($0.last?.sequenceNumber ?? 0) + 1 }

        return StoredRuntimeState(
            threads: threads,
            historyByThread: history,
            summariesByThread: summaries,
            nextHistorySequenceByThread: nextSequence
        )
    }

    private static func persistThreads(
        ids threadIDs: Set<String>,
        from state: StoredRuntimeState,
        in db: Database,
        attachmentStore: RuntimeAttachmentStore
    ) throws {
        let normalized = state.normalized()
        let threads = normalized.threads.filter { threadIDs.contains($0.id) }
        guard !threads.isEmpty else {
            return
        }

        for thread in threads {
            try Self.makeThreadRow(from: thread).insert(db)
            if let summary = normalized.summariesByThread[thread.id] {
                try Self.makeSummaryRow(from: summary).insert(db)
            }
            for record in normalized.historyByThread[thread.id] ?? [] {
                try Self.makeHistoryRow(from: record, attachmentStore: attachmentStore).insert(db)
            }
        }

        for row in try Self.structuredOutputRows(
            from: normalized.historyByThread.filter { threadIDs.contains($0.key) }
        ) {
            try row.insert(db)
        }
    }

    private static func deletePersistedThread(
        _ threadID: String,
        in db: Database
    ) throws {
        try db.execute(
            sql: "DELETE FROM \(RuntimeThreadRow.databaseTableName) WHERE threadID = ?",
            arguments: [threadID]
        )
    }

    private static func fetchHistoryRows(
        threadID: String,
        kinds: Set<AgentHistoryItemKind>?,
        createdAtRange: ClosedRange<Date>?,
        turnID: String?,
        includeRedacted: Bool,
        in db: Database,
        attachmentStore: RuntimeAttachmentStore
    ) throws -> [AgentHistoryRecord] {
        var clauses = ["threadID = ?"]
        var arguments: [any DatabaseValueConvertible] = [threadID]

        if let kinds, !kinds.isEmpty {
            clauses.append("kind IN \(sqlPlaceholders(count: kinds.count))")
            arguments.append(contentsOf: kinds.map(\.rawValue))
        }
        if let createdAtRange {
            clauses.append("createdAt >= ?")
            clauses.append("createdAt <= ?")
            arguments.append(createdAtRange.lowerBound.timeIntervalSince1970)
            arguments.append(createdAtRange.upperBound.timeIntervalSince1970)
        }
        if let turnID {
            clauses.append("turnID = ?")
            arguments.append(turnID)
        }
        if !includeRedacted {
            clauses.append("isRedacted = 0")
        }

        let sql = """
        SELECT * FROM \(RuntimeHistoryRow.databaseTableName)
        WHERE \(clauses.joined(separator: " AND "))
        ORDER BY sequenceNumber ASC
        """
        return try RuntimeHistoryRow.fetchAll(
            db,
            sql: sql,
            arguments: StatementArguments(arguments)
        ).map { try Self.decodeHistoryRecord(from: $0, attachmentStore: attachmentStore) }
    }

    private static func fetchHistoryPage(
        threadID: String,
        query: AgentHistoryQuery,
        in db: Database,
        attachmentStore: RuntimeAttachmentStore
    ) throws -> AgentThreadHistoryPage {
        let limit = max(1, query.limit)
        let kinds = historyKinds(from: query.filter)
        let anchor = try decodeCursorSequence(query.cursor, expectedThreadID: threadID)

        switch query.direction {
        case .backward:
            var clauses = ["threadID = ?"]
            var arguments: [any DatabaseValueConvertible] = [threadID]
            if let kinds, !kinds.isEmpty {
                clauses.append("kind IN \(sqlPlaceholders(count: kinds.count))")
                for kind in kinds { arguments.append(kind.rawValue) }
            }
            if let anchor {
                clauses.append("sequenceNumber < ?")
                arguments.append(anchor)
            }

            let sql = """
            SELECT * FROM \(RuntimeHistoryRow.databaseTableName)
            WHERE \(clauses.joined(separator: " AND "))
            ORDER BY sequenceNumber DESC
            LIMIT \(limit + 1)
            """
            let fetched = try RuntimeHistoryRow.fetchAll(
                db,
                sql: sql,
                arguments: StatementArguments(arguments)
            )
            let hasMoreBefore = fetched.count > limit
            let pageRowsDescending = Array(fetched.prefix(limit))
            let pageRecords = try pageRowsDescending
                .map { try Self.decodeHistoryRecord(from: $0, attachmentStore: attachmentStore) }
                .reversed()

            let hasMoreAfter: Bool
            if let anchor {
                hasMoreAfter = try historyRecordExists(
                    threadID: threadID,
                    kinds: kinds,
                    comparator: "sequenceNumber >= ?",
                    value: anchor,
                    in: db
                )
            } else {
                hasMoreAfter = false
            }

            return AgentThreadHistoryPage(
                threadID: threadID,
                items: pageRecords.map(\.item),
                nextCursor: hasMoreBefore ? makeCursor(threadID: threadID, sequenceNumber: pageRecords.first?.sequenceNumber) : nil,
                previousCursor: hasMoreAfter ? makeCursor(threadID: threadID, sequenceNumber: pageRecords.last?.sequenceNumber) : nil,
                hasMoreBefore: hasMoreBefore,
                hasMoreAfter: hasMoreAfter
            )

        case .forward:
            var clauses = ["threadID = ?"]
            var arguments: [any DatabaseValueConvertible] = [threadID]
            if let kinds, !kinds.isEmpty {
                clauses.append("kind IN \(sqlPlaceholders(count: kinds.count))")
                for kind in kinds { arguments.append(kind.rawValue) }
            }
            if let anchor {
                clauses.append("sequenceNumber > ?")
                arguments.append(anchor)
            }

            let sql = """
            SELECT * FROM \(RuntimeHistoryRow.databaseTableName)
            WHERE \(clauses.joined(separator: " AND "))
            ORDER BY sequenceNumber ASC
            LIMIT \(limit + 1)
            """
            let fetched = try RuntimeHistoryRow.fetchAll(
                db,
                sql: sql,
                arguments: StatementArguments(arguments)
            )
            let hasMoreAfter = fetched.count > limit
            let pageRows = Array(fetched.prefix(limit))
            let pageRecords = try pageRows.map {
                try Self.decodeHistoryRecord(from: $0, attachmentStore: attachmentStore)
            }

            let hasMoreBefore: Bool
            if let anchor {
                hasMoreBefore = try historyRecordExists(
                    threadID: threadID,
                    kinds: kinds,
                    comparator: "sequenceNumber <= ?",
                    value: anchor,
                    in: db
                )
            } else {
                hasMoreBefore = false
            }

            return AgentThreadHistoryPage(
                threadID: threadID,
                items: pageRecords.map(\.item),
                nextCursor: hasMoreAfter ? makeCursor(threadID: threadID, sequenceNumber: pageRecords.last?.sequenceNumber) : nil,
                previousCursor: hasMoreBefore ? makeCursor(threadID: threadID, sequenceNumber: pageRecords.first?.sequenceNumber) : nil,
                hasMoreBefore: hasMoreBefore,
                hasMoreAfter: hasMoreAfter
            )
        }
    }

    private static func historyRecordExists(
        threadID: String,
        kinds: Set<AgentHistoryItemKind>?,
        comparator: String,
        value: Int,
        in db: Database
    ) throws -> Bool {
        var clauses = ["threadID = ?", comparator]
        var arguments: [any DatabaseValueConvertible] = [threadID, value]
        if let kinds, !kinds.isEmpty {
            clauses.append("kind IN \(sqlPlaceholders(count: kinds.count))")
            for kind in kinds { arguments.append(kind.rawValue) }
        }

        let sql = """
        SELECT EXISTS(
            SELECT 1 FROM \(RuntimeHistoryRow.databaseTableName)
            WHERE \(clauses.joined(separator: " AND "))
        )
        """
        return try Bool.fetchOne(db, sql: sql, arguments: StatementArguments(arguments)) ?? false
    }

    private static func threadMetadataSQL(for query: ThreadMetadataQuery) -> String {
        var sql = "SELECT * FROM \(RuntimeThreadRow.databaseTableName)"
        var clauses: [String] = []
        if let threadIDs = query.threadIDs, !threadIDs.isEmpty {
            clauses.append("threadID IN \(sqlPlaceholders(count: threadIDs.count))")
        }
        if let statuses = query.statuses, !statuses.isEmpty {
            clauses.append("status IN \(sqlPlaceholders(count: statuses.count))")
        }
        if query.updatedAtRange != nil {
            clauses.append("updatedAt >= ?")
            clauses.append("updatedAt <= ?")
        }
        if !clauses.isEmpty {
            sql += " WHERE " + clauses.joined(separator: " AND ")
        }
        sql += " ORDER BY " + threadSortClause(query.sort)
        if let limit = query.limit {
            sql += " LIMIT \(max(0, limit))"
        }
        return sql
    }

    private static func threadMetadataArguments(for query: ThreadMetadataQuery) -> [any DatabaseValueConvertible] {
        var arguments: [any DatabaseValueConvertible] = []
        if let threadIDs = query.threadIDs, !threadIDs.isEmpty {
            for threadID in threadIDs {
                arguments.append(threadID)
            }
        }
        if let statuses = query.statuses, !statuses.isEmpty {
            for status in statuses {
                arguments.append(status.rawValue)
            }
        }
        if let range = query.updatedAtRange {
            arguments.append(range.lowerBound.timeIntervalSince1970)
            arguments.append(range.upperBound.timeIntervalSince1970)
        }
        return arguments
    }

    private static func pendingStateSQL(for query: PendingStateQuery) -> String {
        var sql = "SELECT * FROM \(RuntimeSummaryRow.databaseTableName) WHERE pendingStateKind IS NOT NULL"
        if let threadIDs = query.threadIDs, !threadIDs.isEmpty {
            sql += " AND threadID IN \(sqlPlaceholders(count: threadIDs.count))"
        }
        if let kinds = query.kinds, !kinds.isEmpty {
            sql += " AND pendingStateKind IN \(sqlPlaceholders(count: kinds.count))"
        }
        sql += " ORDER BY updatedAt " + sortDirection(for: query.sort)
        if let limit = query.limit {
            sql += " LIMIT \(max(0, limit))"
        }
        return sql
    }

    private static func pendingStateArguments(for query: PendingStateQuery) -> [any DatabaseValueConvertible] {
        var arguments: [any DatabaseValueConvertible] = []
        if let threadIDs = query.threadIDs, !threadIDs.isEmpty {
            for threadID in threadIDs {
                arguments.append(threadID)
            }
        }
        if let kinds = query.kinds, !kinds.isEmpty {
            for kind in kinds {
                arguments.append(kind.rawValue)
            }
        }
        return arguments
    }

    private static func structuredOutputSQL(for query: StructuredOutputQuery) -> String {
        var sql = "SELECT * FROM \(RuntimeStructuredOutputRow.databaseTableName)"
        var clauses: [String] = []
        if let threadIDs = query.threadIDs, !threadIDs.isEmpty {
            clauses.append("threadID IN \(sqlPlaceholders(count: threadIDs.count))")
        }
        if let formatNames = query.formatNames, !formatNames.isEmpty {
            clauses.append("formatName IN \(sqlPlaceholders(count: formatNames.count))")
        }
        if !clauses.isEmpty {
            sql += " WHERE " + clauses.joined(separator: " AND ")
        }
        sql += " ORDER BY committedAt " + sortDirection(for: query.sort)
        if let limit = query.limit, !query.latestOnly {
            sql += " LIMIT \(max(0, limit))"
        }
        return sql
    }

    private static func structuredOutputArguments(for query: StructuredOutputQuery) -> [any DatabaseValueConvertible] {
        var arguments: [any DatabaseValueConvertible] = []
        if let threadIDs = query.threadIDs, !threadIDs.isEmpty {
            for threadID in threadIDs {
                arguments.append(threadID)
            }
        }
        if let formatNames = query.formatNames, !formatNames.isEmpty {
            for formatName in formatNames {
                arguments.append(formatName)
            }
        }
        return arguments
    }

    private static func threadSnapshotSQL(for query: ThreadSnapshotQuery) -> String {
        var sql = "SELECT * FROM \(RuntimeSummaryRow.databaseTableName)"
        if let threadIDs = query.threadIDs, !threadIDs.isEmpty {
            sql += " WHERE threadID IN \(sqlPlaceholders(count: threadIDs.count))"
        }
        sql += " ORDER BY " + snapshotSortClause(query.sort)
        if let limit = query.limit {
            sql += " LIMIT \(max(0, limit))"
        }
        return sql
    }

    private static func threadSnapshotArguments(for query: ThreadSnapshotQuery) -> [any DatabaseValueConvertible] {
        guard let threadIDs = query.threadIDs, !threadIDs.isEmpty else {
            return []
        }
        return threadIDs.map { $0 as any DatabaseValueConvertible }
    }

    private static func defaultLegacyImportURL(for url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("json")
    }

    private static func sqlPlaceholders(count: Int) -> String {
        "(" + Array(repeating: "?", count: count).joined(separator: ", ") + ")"
    }

    private static func threadSortClause(_ sort: AgentThreadMetadataSort) -> String {
        switch sort {
        case let .updatedAt(order):
            "updatedAt \(order == .ascending ? "ASC" : "DESC"), threadID ASC"
        case let .createdAt(order):
            "createdAt \(order == .ascending ? "ASC" : "DESC"), threadID ASC"
        }
    }

    private static func snapshotSortClause(_ sort: AgentThreadSnapshotSort) -> String {
        switch sort {
        case let .updatedAt(order):
            "updatedAt \(order == .ascending ? "ASC" : "DESC"), threadID ASC"
        case let .createdAt(order):
            "createdAt \(order == .ascending ? "ASC" : "DESC"), threadID ASC"
        }
    }

    private static func sortDirection(for sort: AgentPendingStateSort) -> String {
        switch sort {
        case let .updatedAt(order):
            order == .ascending ? "ASC" : "DESC"
        }
    }

    private static func sortDirection(for sort: AgentStructuredOutputSort) -> String {
        switch sort {
        case let .committedAt(order):
            order == .ascending ? "ASC" : "DESC"
        }
    }

    private static func historyKinds(from filter: AgentHistoryFilter?) -> Set<AgentHistoryItemKind>? {
        guard let filter else {
            return nil
        }

        var kinds: Set<AgentHistoryItemKind> = []
        if filter.includeMessages { kinds.insert(.message) }
        if filter.includeToolCalls { kinds.insert(.toolCall) }
        if filter.includeToolResults { kinds.insert(.toolResult) }
        if filter.includeStructuredOutputs { kinds.insert(.structuredOutput) }
        if filter.includeApprovals { kinds.insert(.approval) }
        if filter.includeSystemEvents { kinds.insert(.systemEvent) }
        return kinds
    }

    private static func makeCursor(threadID: String, sequenceNumber: Int?) -> AgentHistoryCursor? {
        guard let sequenceNumber else {
            return nil
        }

        let payload = GRDBHistoryCursorPayload(
            version: 1,
            threadID: threadID,
            sequenceNumber: sequenceNumber
        )
        let data = (try? JSONEncoder().encode(payload)) ?? Data()
        let base64 = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return AgentHistoryCursor(rawValue: base64)
    }

    private static func decodeCursorSequence(
        _ cursor: AgentHistoryCursor?,
        expectedThreadID: String
    ) throws -> Int? {
        guard let cursor else {
            return nil
        }

        let padded = cursor.rawValue
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = padded.count % 4
        let adjusted = padded + String(repeating: "=", count: remainder == 0 ? 0 : 4 - remainder)

        guard let data = Data(base64Encoded: adjusted) else {
            throw AgentRuntimeError.invalidHistoryCursor()
        }

        let payload = try JSONDecoder().decode(GRDBHistoryCursorPayload.self, from: data)
        guard payload.threadID == expectedThreadID else {
            throw AgentRuntimeError.invalidHistoryCursor()
        }
        return payload.sequenceNumber
    }

    private static func makeThreadRow(from thread: AgentThread) throws -> RuntimeThreadRow {
        RuntimeThreadRow(
            threadID: thread.id,
            createdAt: thread.createdAt.timeIntervalSince1970,
            updatedAt: thread.updatedAt.timeIntervalSince1970,
            status: thread.status.rawValue,
            encodedThread: try JSONEncoder().encode(thread)
        )
    }

    private static func makeSummaryRow(from summary: AgentThreadSummary) throws -> RuntimeSummaryRow {
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

    private static func makeHistoryRow(
        from record: AgentHistoryRecord,
        attachmentStore: RuntimeAttachmentStore
    ) throws -> RuntimeHistoryRow {
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
            isRedacted: record.redaction != nil,
            encodedRecord: try JSONEncoder().encode(persisted)
        )
    }

    private static func structuredOutputRows(
        from historyByThread: [String: [AgentHistoryRecord]]
    ) throws -> [RuntimeStructuredOutputRow] {
        try historyByThread.values
            .flatMap { $0 }
            .compactMap { record -> RuntimeStructuredOutputRow? in
                switch record.item {
                case let .structuredOutput(output):
                    return try Self.makeStructuredOutputRow(
                        id: "structured:\(record.id)",
                        record: output
                    )

                case let .message(message):
                    guard let metadata = message.structuredOutput else {
                        return nil
                    }
                    return try Self.makeStructuredOutputRow(
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

    private static func makeStructuredOutputRow(
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

    private static func decodeThread(from row: RuntimeThreadRow) throws -> AgentThread {
        try JSONDecoder().decode(AgentThread.self, from: row.encodedThread)
    }

    private static func decodeSummary(from row: RuntimeSummaryRow) throws -> AgentThreadSummary {
        try JSONDecoder().decode(AgentThreadSummary.self, from: row.encodedSummary)
    }

    private static func decodeHistoryRecord(
        from row: RuntimeHistoryRow,
        attachmentStore: RuntimeAttachmentStore
    ) throws -> AgentHistoryRecord {
        let decoder = JSONDecoder()
        if let persisted = try? decoder.decode(PersistedAgentHistoryRecord.self, from: row.encodedRecord) {
            return try persisted.decode(using: attachmentStore)
        }
        return try decoder.decode(AgentHistoryRecord.self, from: row.encodedRecord)
    }

    private static func decodeStructuredOutputRecord(from row: RuntimeStructuredOutputRow) throws -> AgentStructuredOutputRecord {
        try JSONDecoder().decode(AgentStructuredOutputRecord.self, from: row.encodedRecord)
    }

    private static func makeMigrator() -> DatabaseMigrator {
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

            try db.execute(sql: "PRAGMA user_version = \(currentStoreSchemaVersion)")
        }

        return migrator
    }

    private static func sortPendingStateRecords(
        _ records: [AgentPendingStateRecord],
        using sort: AgentPendingStateSort
    ) -> [AgentPendingStateRecord] {
        records.sorted { lhs, rhs in
            switch sort {
            case let .updatedAt(order):
                if lhs.updatedAt == rhs.updatedAt {
                    return lhs.threadID < rhs.threadID
                }
                return order == .ascending ? lhs.updatedAt < rhs.updatedAt : lhs.updatedAt > rhs.updatedAt
            }
        }
    }

    private static func sortStructuredOutputRecords(
        _ records: [AgentStructuredOutputRecord],
        using sort: AgentStructuredOutputSort
    ) -> [AgentStructuredOutputRecord] {
        records.sorted { lhs, rhs in
            switch sort {
            case let .committedAt(order):
                if lhs.committedAt == rhs.committedAt {
                    return (lhs.messageID ?? lhs.turnID) < (rhs.messageID ?? rhs.turnID)
                }
                return order == .ascending ? lhs.committedAt < rhs.committedAt : lhs.committedAt > rhs.committedAt
            }
        }
    }

    private static func sortThreadSnapshots(
        _ snapshots: [AgentThreadSnapshot],
        using sort: AgentThreadSnapshotSort
    ) -> [AgentThreadSnapshot] {
        snapshots.sorted { lhs, rhs in
            switch sort {
            case let .updatedAt(order):
                if lhs.updatedAt == rhs.updatedAt {
                    return lhs.threadID < rhs.threadID
                }
                return order == .ascending ? lhs.updatedAt < rhs.updatedAt : lhs.updatedAt > rhs.updatedAt
            case let .createdAt(order):
                if lhs.createdAt == rhs.createdAt {
                    return lhs.threadID < rhs.threadID
                }
                return order == .ascending ? lhs.createdAt < rhs.createdAt : lhs.createdAt > rhs.createdAt
            }
        }
    }

    private func readUserVersion() async throws -> Int {
        try await dbQueue.read { db in
            try Int.fetchOne(db, sql: "PRAGMA user_version;") ?? 0
        }
    }
}

private struct RuntimeThreadRow: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "runtime_threads"

    let threadID: String
    let createdAt: Double
    let updatedAt: Double
    let status: String
    let encodedThread: Data
}

private struct RuntimeSummaryRow: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "runtime_summaries"

    let threadID: String
    let createdAt: Double
    let updatedAt: Double
    let latestItemAt: Double?
    let itemCount: Int?
    let pendingStateKind: String?
    let latestStructuredOutputFormatName: String?
    let encodedSummary: Data
}

private struct RuntimeHistoryRow: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "runtime_history_items"

    let storageID: String
    let recordID: String
    let threadID: String
    let sequenceNumber: Int
    let createdAt: Double
    let kind: String
    let turnID: String?
    let isRedacted: Bool
    let encodedRecord: Data
}

private struct RuntimeStructuredOutputRow: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "runtime_structured_outputs"

    let outputID: String
    let threadID: String
    let formatName: String
    let committedAt: Double
    let encodedRecord: Data
}

private struct GRDBHistoryCursorPayload: Codable {
    let version: Int
    let threadID: String
    let sequenceNumber: Int
}

private extension AgentHistoryItem {
    var threadID: String {
        switch self {
        case let .message(message):
            message.threadID
        case let .toolCall(record):
            record.invocation.threadID
        case let .toolResult(record):
            record.threadID
        case let .structuredOutput(record):
            record.threadID
        case let .approval(record):
            record.request?.threadID ?? record.resolution?.threadID ?? ""
        case let .systemEvent(record):
            record.threadID
        }
    }
}
