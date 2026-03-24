import Foundation
import GRDB

public actor SQLiteMemoryStore: MemoryStoring {
    private let url: URL
    private let dbQueue: DatabaseQueue
    private let schema: SQLiteMemoryStoreSchema
    private let repository: SQLiteMemoryStoreRepository
    private let migrator: DatabaseMigrator

    public init(url: URL) throws {
        self.url = url
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
        configuration.label = "CodexKit.SQLiteMemoryStore"
        dbQueue = try DatabaseQueue(path: url.path, configuration: configuration)
        migrator = schema.makeMigrator()

        let existingVersion = try dbQueue.read { db in
            try schema.existingVersion(in: db)
        }
        if existingVersion > schema.currentVersion {
            throw MemoryStoreError.unsupportedSchemaVersion(existingVersion)
        }

        try migrator.migrate(dbQueue)
    }

    public func put(_ record: MemoryRecord) async throws {
        try MemoryQueryEngine.validateNamespace(record.namespace)
        let repository = self.repository
        try await writeTransaction { db in
            try repository.ensureRecordIDAvailable(record.id, namespace: record.namespace, in: db)
            if let dedupeKey = record.dedupeKey {
                try repository.ensureDedupeKeyAvailable(dedupeKey, namespace: record.namespace, in: db)
            }
            try repository.upsertRecord(record, in: db)
        }
    }

    public func putMany(_ records: [MemoryRecord]) async throws {
        let repository = self.repository
        try await writeTransaction { db in
            for record in records {
                try MemoryQueryEngine.validateNamespace(record.namespace)
                try repository.ensureRecordIDAvailable(record.id, namespace: record.namespace, in: db)
                if let dedupeKey = record.dedupeKey {
                    try repository.ensureDedupeKeyAvailable(dedupeKey, namespace: record.namespace, in: db)
                }
                try repository.upsertRecord(record, in: db)
            }
        }
    }

    public func upsert(_ record: MemoryRecord, dedupeKey: String) async throws {
        try MemoryQueryEngine.validateNamespace(record.namespace)
        let repository = self.repository
        try await writeTransaction { db in
            try repository.deleteRecord(withDedupeKey: dedupeKey, namespace: record.namespace, in: db)
            try repository.deleteRecord(id: record.id, namespace: record.namespace, in: db)
            var updatedRecord = record
            updatedRecord.dedupeKey = dedupeKey
            try repository.upsertRecord(updatedRecord, in: db)
        }
    }

    public func query(_ query: MemoryQuery) async throws -> MemoryQueryResult {
        try MemoryQueryEngine.validateNamespace(query.namespace)
        let records = try await dbQueue.read { db in
            try repository.loadRecords(namespace: query.namespace, in: db)
        }
        let rawScores = try await dbQueue.read { db in
            try repository.loadRawFTSScores(
                namespace: query.namespace,
                queryText: query.text,
                in: db
            )
        }

        let candidates = records.map { record in
            MemoryQueryEngine.Candidate(
                record: record,
                textScore: rawScores[record.id],
                textScoreOrdering: .lowerIsBetter
            )
        }

        return try MemoryQueryEngine.evaluate(
            candidates: candidates,
            query: query
        )
    }

    public func record(
        id: String,
        namespace: String
    ) async throws -> MemoryRecord? {
        try MemoryQueryEngine.validateNamespace(namespace)
        return try await dbQueue.read { db in
            try repository.loadRecord(id: id, namespace: namespace, in: db)
        }
    }

    public func list(_ query: MemoryRecordListQuery) async throws -> [MemoryRecord] {
        try MemoryQueryEngine.validateNamespace(query.namespace)
        return try await dbQueue.read { db in
            try repository.loadRecords(namespace: query.namespace, in: db)
                .filter { record in
                    if !query.includeArchived, record.status == MemoryRecordStatus.archived {
                        return false
                    }
                    if !query.scopes.isEmpty, !query.scopes.contains(record.scope) {
                        return false
                    }
                    if !query.kinds.isEmpty, !query.kinds.contains(record.kind) {
                        return false
                    }
                    return true
                }
                .sorted {
                    if $0.effectiveDate == $1.effectiveDate {
                        return $0.id < $1.id
                    }
                    return $0.effectiveDate > $1.effectiveDate
                }
                .prefix(query.limit ?? .max)
                .map { $0 }
        }
    }

    public func diagnostics(namespace: String) async throws -> MemoryStoreDiagnostics {
        try MemoryQueryEngine.validateNamespace(namespace)
        let records = try await dbQueue.read { db in
            try repository.loadRecords(namespace: namespace, in: db)
        }
        let schemaVersion = try await dbQueue.read { db in
            try schema.existingVersion(in: db)
        }
        return MemoryStoreDiagnostics(
            namespace: namespace,
            implementation: "sqlite",
            schemaVersion: schemaVersion,
            totalRecords: records.count,
            activeRecords: records.filter { $0.status == MemoryRecordStatus.active }.count,
            archivedRecords: records.filter { $0.status == MemoryRecordStatus.archived }.count,
            countsByScope: Dictionary(grouping: records, by: { $0.scope }).mapValues { $0.count },
            countsByKind: Dictionary(grouping: records, by: { $0.kind }).mapValues { $0.count }
        )
    }

    public func compact(_ request: MemoryCompactionRequest) async throws {
        try MemoryQueryEngine.validateNamespace(request.replacement.namespace)
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
            try repository.upsertRecord(request.replacement, in: db)
            for sourceID in request.sourceIDs {
                try repository.archiveRecord(id: sourceID, namespace: request.replacement.namespace, in: db)
            }
        }
    }

    public func archive(ids: [String], namespace: String) async throws {
        try MemoryQueryEngine.validateNamespace(namespace)
        let repository = self.repository
        try await writeTransaction { db in
            for id in ids {
                try repository.archiveRecord(id: id, namespace: namespace, in: db)
            }
        }
    }

    public func delete(ids: [String], namespace: String) async throws {
        try MemoryQueryEngine.validateNamespace(namespace)
        let repository = self.repository
        try await writeTransaction { db in
            for id in ids {
                try repository.deleteRecord(id: id, namespace: namespace, in: db)
            }
        }
    }

    @discardableResult
    public func pruneExpired(
        now: Date,
        namespace: String
    ) async throws -> Int {
        try MemoryQueryEngine.validateNamespace(namespace)
        let repository = self.repository
        let expiredIDs = try await dbQueue.read { db in
            let records = try repository.loadRecords(namespace: namespace, in: db)
            return records.compactMap { record -> String? in
                guard !record.isPinned else {
                    return nil
                }
                guard record.status == MemoryRecordStatus.active else {
                    return nil
                }
                guard let expiresAt = record.expiresAt, expiresAt <= now else {
                    return nil
                }
                return record.id
            }
        }

        try await writeTransaction { db in
            for id in expiredIDs {
                try repository.deleteRecord(id: id, namespace: namespace, in: db)
            }
        }
        return expiredIDs.count
    }

    private func writeTransaction(_ operation: @escaping @Sendable (Database) throws -> Void) async throws {
        try await dbQueue.writeWithoutTransaction { db in
            try db.inTransaction {
                try operation(db)
                return .commit
            }
        }
    }
}
