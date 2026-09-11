import Foundation
import CodexKit
import GRDB

public actor SQLiteMemoryStore: MemoryStoring {
    private let url: URL
    private let logger: AgentLogger
    private let dbQueue: DatabaseQueue
    private let schema: SQLiteMemoryStoreSchema
    private let repository: SQLiteMemoryStoreRepository
    private let migrator: DatabaseMigrator
    private var isPrepared = false
    private var preparationTask: Task<Void, Error>?
    private var preparationGeneration: UInt64 = 0
    private var latestQueryMaterializedRecordCount = 0

    public init(
        logging: AgentLoggingConfiguration = .disabled
    ) throws {
        let layout = try CodexKitManagedStorageLayout.live()
        try self.init(url: layout.fileURL(for: .sqliteMemory), logging: logging)
    }

    package init(
        url: URL,
        logging: AgentLoggingConfiguration = .disabled
    ) throws {
        self.url = url
        self.logger = AgentLogger(configuration: logging)
        self.schema = SQLiteMemoryStoreSchema()
        let codec = SQLiteMemoryStoreCodec()
        self.repository = SQLiteMemoryStoreRepository(codec: codec)

        let directory = url.deletingLastPathComponent()
        if !directory.path.isEmpty {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }

        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.busyMode = .timeout(5)
        configuration.label = "CodexKit.SQLiteMemoryStore"
        dbQueue = try DatabaseQueue(path: url.path, configuration: configuration)
        migrator = schema.makeMigrator()
        logger.info(.memory, "SQLite memory store configured.", metadata: ["url": url.path])
    }

    public func prepare() async throws {
        try await ensurePrepared()
    }

    public func put(_ record: MemoryRecord) async throws {
        logger.debug(.memory, "Writing memory record.", metadata: ["namespace": record.namespace, "record_id": record.id])
        try MemoryQueryEngine.validate(record)
        let repository = self.repository
        try await writeTransaction { db in
            try insertNewRecord(record, repository: repository, in: db)
        }
    }

    public func putMany(_ records: [MemoryRecord]) async throws {
        logger.debug(.memory, "Writing many memory records.", metadata: ["count": "\(records.count)"])
        try MemoryQueryEngine.validateBulkRecords(records)
        var pendingIDs = Set<String>()
        var pendingDedupeKeys = Set<String>()
        for record in records {
            let recordKey = "\(record.namespace.utf8.count):\(record.namespace)\(record.id)"
            guard pendingIDs.insert(recordKey).inserted else {
                throw MemoryStoreError.duplicateRecordID(record.id)
            }
            if let dedupeKey = record.dedupeKey {
                let ownershipKey = "\(record.namespace.utf8.count):\(record.namespace)\(dedupeKey)"
                guard pendingDedupeKeys.insert(ownershipKey).inserted else {
                    throw MemoryStoreError.duplicateDedupeKey(dedupeKey)
                }
            }
        }
        let repository = self.repository
        try await writeTransaction { db in
            for record in records {
                try insertNewRecord(record, repository: repository, in: db)
            }
        }
    }

    public func upsert(_ record: MemoryRecord, dedupeKey: String) async throws {
        logger.debug(.memory, "Upserting memory record by dedupe key.", metadata: ["namespace": record.namespace, "record_id": record.id])
        let updatedRecord = {
            var value = record
            value.dedupeKey = dedupeKey
            return value
        }()
        try MemoryQueryEngine.validate(updatedRecord)
        let repository = self.repository
        try await writeTransaction { db in
            try repository.deleteRecord(withDedupeKey: dedupeKey, namespace: record.namespace, in: db)
            try repository.deleteRecord(id: record.id, namespace: record.namespace, in: db)
            try repository.insertRecord(updatedRecord, in: db)
        }
    }

    public func query(_ query: MemoryQuery) async throws -> MemoryQueryResult {
        try await ensurePrepared()
        logger.debug(
            .memory,
            "Querying memory store.",
            metadata: [
                "namespace": query.namespace,
                "text_length_at_most": "\(query.text?.utf8.prefix(MemoryStoreLimits.maximumQueryTextByteCount + 1).count ?? 0)"
            ]
        )
        try MemoryQueryEngine.validate(query)
        let repository = self.repository
        let now = Date()
        latestQueryMaterializedRecordCount = 0
        let resultLimit = max(0, query.limit)
        guard query.maxCharacters > 0 else {
            return MemoryQueryResult(matches: [], truncated: false)
        }
        guard resultLimit > 0 else {
            let hasCandidates = try await dbQueue.read { db in
                try repository.hasRecords(
                    matching: query,
                    now: now,
                    maxCharacters: query.maxCharacters,
                    in: db
                )
            }
            return MemoryQueryResult(matches: [], truncated: hasCandidates)
        }

        let page = try await dbQueue.read { db in
            try repository.loadRankedRecords(
                matching: query,
                now: now,
                limit: resultLimit,
                maxCharacters: query.maxCharacters,
                in: db
            )
        }
        latestQueryMaterializedRecordCount = page.records.count
        let matches = page.records.map { ranked in
            MemoryQueryMatch(record: ranked.record, explanation: ranked.explanation)
        }

        return MemoryQueryResult(
            matches: matches,
            truncated: page.truncated,
            nextCursor: page.nextCursor
        )
    }

    public func record(
        id: String,
        namespace: String
    ) async throws -> MemoryRecord? {
        try await ensurePrepared()
        try MemoryQueryEngine.validateNamespace(namespace)
        try MemoryQueryEngine.validateBulkIdentifiers([id], operation: "record lookup")
        return try await dbQueue.read { db in
            try repository.loadRecord(id: id, namespace: namespace, in: db)
        }
    }

    public func list(_ query: MemoryRecordListQuery) async throws -> [MemoryRecord] {
        try await ensurePrepared()
        try MemoryQueryEngine.validate(query)
        let repository = self.repository
        return try await dbQueue.read { db in
            try repository.loadRecords(matching: query, in: db)
        }
    }

    public func diagnostics(namespace: String) async throws -> MemoryStoreDiagnostics {
        try await ensurePrepared()
        try MemoryQueryEngine.validateNamespace(namespace)
        let repository = self.repository
        let schema = self.schema
        return try await dbQueue.read { db in
            try repository.loadDiagnostics(
                namespace: namespace,
                schemaVersion: schema.existingVersion(in: db),
                in: db
            )
        }
    }

    public func compact(_ request: MemoryCompactionRequest) async throws {
        try MemoryQueryEngine.validate(request)
        let repository = self.repository
        try await writeTransaction { db in
            try repository.ensureRecordIDAvailable(
                request.replacement.id,
                namespace: request.replacement.namespace,
                in: db
            )
            if let dedupeKey = request.replacement.dedupeKey {
                try repository.ensureDedupeKeyAvailable(
                    dedupeKey,
                    namespace: request.replacement.namespace,
                    in: db
                )
            }
            try repository.insertRecord(request.replacement, in: db)
            try repository.archiveRecords(
                ids: request.sourceIDs,
                namespace: request.replacement.namespace,
                in: db
            )
        }
    }

    public func archive(ids: [String], namespace: String) async throws {
        try MemoryQueryEngine.validateNamespace(namespace)
        try MemoryQueryEngine.validateBulkIdentifiers(ids, operation: "archive")
        let repository = self.repository
        try await writeTransaction { db in
            try repository.archiveRecords(ids: ids, namespace: namespace, in: db)
        }
    }

    public func delete(ids: [String], namespace: String) async throws {
        try MemoryQueryEngine.validateNamespace(namespace)
        try MemoryQueryEngine.validateBulkIdentifiers(ids, operation: "delete")
        let repository = self.repository
        try await writeTransaction { db in
            try repository.deleteRecords(ids: ids, namespace: namespace, in: db)
        }
    }

    @discardableResult
    public func pruneExpired(
        now: Date,
        namespace: String
    ) async throws -> Int {
        try MemoryQueryEngine.validateNamespace(namespace)
        let repository = self.repository
        return try await writeTransaction { db in
            try repository.deleteExpiredRecords(
                now: now,
                namespace: namespace,
                in: db
            )
        }
    }

    func materializedRecordCountForLatestQuery() -> Int {
        latestQueryMaterializedRecordCount
    }

    func rankedQueryPlan(_ query: MemoryQuery) async throws -> [String] {
        try MemoryQueryEngine.validate(query)
        try await ensurePrepared()
        let repository = self.repository
        return try await dbQueue.read { db in
            try repository.rankedQueryPlan(
                matching: query,
                now: Date(),
                limit: query.limit,
                maxCharacters: query.maxCharacters,
                in: db
            )
        }
    }

    func rankedQueryVirtualMachineSteps(_ query: MemoryQuery) async throws -> Int {
        try MemoryQueryEngine.validate(query)
        try await ensurePrepared()
        let repository = self.repository
        return try await dbQueue.read { db in
            try repository.rankedQueryVirtualMachineSteps(
                matching: query,
                now: Date(),
                limit: query.limit,
                maxCharacters: query.maxCharacters,
                in: db
            )
        }
    }

    private func writeTransaction<Result: Sendable>(
        _ operation: @escaping @Sendable (Database) throws -> Result
    ) async throws -> Result {
        try await ensurePrepared()
        return try await RuntimeStoreMutationCoordinator.shared.perform(
            for: migrationCoordinationRootURL
        ) {
            try await self.writeTransactionWithoutCoordination(operation)
        }
    }

    private func writeTransactionWithoutCoordination<Result: Sendable>(
        _ operation: @escaping @Sendable (Database) throws -> Result
    ) async throws -> Result {
        return try await dbQueue.writeWithoutTransaction { db in
            var result: Result?
            try db.inTransaction {
                result = try operation(db)
                return .commit
            }
            guard let result else {
                throw SQLiteMemoryStoreInternalError.missingTransactionResult
            }
            return result
        }
    }

    private func ensurePrepared() async throws {
        if isPrepared { return }

        let task: Task<Void, Error>
        let generation: UInt64
        if let preparationTask {
            task = preparationTask
            generation = preparationGeneration
        } else {
            preparationGeneration &+= 1
            generation = preparationGeneration
            let created = Task { try self.performPreparation() }
            preparationTask = created
            task = created
        }

        do {
            try await task.value
            if preparationGeneration == generation {
                isPrepared = true
                preparationTask = nil
            }
        } catch {
            if preparationGeneration == generation {
                preparationTask = nil
            }
            throw error
        }
    }

    private func performPreparation() throws {
        let existingVersion = try dbQueue.read { db in
            try schema.existingVersion(in: db)
        }
        if existingVersion > schema.currentVersion {
            throw MemoryStoreError.unsupportedSchemaVersion(existingVersion)
        }
        try migrator.migrate(dbQueue)
        logger.info(.memory, "SQLite memory store prepared.", metadata: ["url": url.path])
    }
}

private enum SQLiteMemoryStoreInternalError: Error {
    case missingTransactionResult
}

extension SQLiteMemoryStore: StoreMigrationIdentifying, StoreMigrationCoordinating {
    package nonisolated var storeMigrationIdentity: StoreMigrationIdentity {
        StoreMigrationIdentity(kind: .memory, url: url)
    }

    package nonisolated var migrationCoordinationRootURL: URL {
        StoreMigrationCoordinationRoot.memoryStore(at: url)
    }
}

private func insertNewRecord(
    _ record: MemoryRecord,
    repository: SQLiteMemoryStoreRepository,
    in db: Database
) throws {
    do {
        try repository.insertRecord(record, in: db)
    } catch {
        do {
            try repository.ensureRecordIDAvailable(
                record.id,
                namespace: record.namespace,
                in: db
            )
            if let dedupeKey = record.dedupeKey {
                try repository.ensureDedupeKeyAvailable(
                    dedupeKey,
                    namespace: record.namespace,
                    in: db
                )
            }
        } catch let storeError as MemoryStoreError {
            throw storeError
        }
        throw error
    }
}
