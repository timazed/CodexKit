import Foundation
import GRDB

private struct SQLiteMemoryStoreSchema: Sendable {
    let currentVersion = 1

    func existingVersion(in db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "PRAGMA user_version;") ?? 0
    }

    func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("memory_store_v1") { db in
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS memory_records (
                namespace TEXT NOT NULL,
                id TEXT NOT NULL,
                scope TEXT NOT NULL,
                kind TEXT NOT NULL,
                summary TEXT NOT NULL,
                evidence_json TEXT NOT NULL,
                importance REAL NOT NULL,
                created_at REAL NOT NULL,
                observed_at REAL,
                expires_at REAL,
                tags_json TEXT NOT NULL,
                related_ids_json TEXT NOT NULL,
                dedupe_key TEXT,
                is_pinned INTEGER NOT NULL,
                attributes_json TEXT,
                status TEXT NOT NULL,
                PRIMARY KEY(namespace, id)
            );
            """)

            try db.execute(sql: """
            CREATE UNIQUE INDEX IF NOT EXISTS memory_records_namespace_dedupe
            ON memory_records(namespace, dedupe_key)
            WHERE dedupe_key IS NOT NULL;
            """)
            try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS memory_records_namespace_scope
            ON memory_records(namespace, scope);
            """)
            try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS memory_records_namespace_kind
            ON memory_records(namespace, kind);
            """)
            try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS memory_records_namespace_status
            ON memory_records(namespace, status);
            """)

            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS memory_tags (
                namespace TEXT NOT NULL,
                record_id TEXT NOT NULL,
                tag TEXT NOT NULL,
                FOREIGN KEY(namespace, record_id)
                    REFERENCES memory_records(namespace, id)
                    ON DELETE CASCADE
            );
            """)
            try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS memory_tags_lookup
            ON memory_tags(namespace, tag, record_id);
            """)

            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS memory_related_ids (
                namespace TEXT NOT NULL,
                record_id TEXT NOT NULL,
                related_id TEXT NOT NULL,
                FOREIGN KEY(namespace, record_id)
                    REFERENCES memory_records(namespace, id)
                    ON DELETE CASCADE
            );
            """)
            try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS memory_related_lookup
            ON memory_related_ids(namespace, related_id, record_id);
            """)

            try db.execute(sql: """
            CREATE VIRTUAL TABLE IF NOT EXISTS memory_fts
            USING fts5(namespace UNINDEXED, record_id UNINDEXED, content);
            """)

            try db.execute(sql: "PRAGMA user_version = \(currentVersion)")
        }

        return migrator
    }
}

private struct SQLiteMemoryStoreCodec: Sendable {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func encode<T: Encodable>(_ value: T) throws -> String {
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    func encodeNullable<T: Encodable>(_ value: T?) throws -> String? {
        guard let value else {
            return nil
        }
        return try encode(value)
    }

    func decode<T: Decodable>(_ type: T.Type, from string: String) throws -> T {
        try decoder.decode(type, from: Data(string.utf8))
    }

    func decodeNullable<T: Decodable>(_ type: T.Type, from string: String?) throws -> T? {
        guard let string else {
            return nil
        }
        return try decode(type, from: string)
    }

    func makeFTSQuery(from value: String?) -> String {
        let tokens = MemoryQueryEngine.tokenize(value)
        guard !tokens.isEmpty else {
            return ""
        }
        return tokens.joined(separator: " OR ")
    }
}

private struct SQLiteMemoryStoreRepository: Sendable {
    let codec: SQLiteMemoryStoreCodec

    func ensureRecordIDAvailable(
        _ id: String,
        namespace: String,
        in db: Database
    ) throws {
        if try recordExists(id: id, namespace: namespace, in: db) {
            throw MemoryStoreError.duplicateRecordID(id)
        }
    }

    func ensureDedupeKeyAvailable(
        _ dedupeKey: String,
        namespace: String,
        in db: Database
    ) throws {
        if try recordExists(dedupeKey: dedupeKey, namespace: namespace, in: db) {
            throw MemoryStoreError.duplicateDedupeKey(dedupeKey)
        }
    }

    func loadRecords(
        namespace: String,
        in db: Database
    ) throws -> [MemoryRecord] {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT
                id, scope, kind, summary, evidence_json, importance,
                created_at, observed_at, expires_at, tags_json,
                related_ids_json, dedupe_key, is_pinned, attributes_json, status
            FROM memory_records
            WHERE namespace = ?;
            """,
            arguments: [namespace]
        )

        return try rows.map { row in
            try makeRecord(from: row, namespace: namespace)
        }
    }

    func loadRawFTSScores(
        namespace: String,
        queryText: String?,
        in db: Database
    ) throws -> [String: Double] {
        let matchQuery = codec.makeFTSQuery(from: queryText)
        guard !matchQuery.isEmpty else {
            return [:]
        }

        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT record_id, bm25(memory_fts) AS score
            FROM memory_fts
            WHERE namespace = ? AND memory_fts MATCH ?;
            """,
            arguments: [namespace, matchQuery]
        )

        var scores: [String: Double] = [:]
        for row in rows {
            let recordID: String = row["record_id"]
            let score: Double = row["score"]
            scores[recordID] = score
        }
        return scores
    }

    func loadRecord(
        id: String,
        namespace: String,
        in db: Database
    ) throws -> MemoryRecord? {
        let row = try Row.fetchOne(
            db,
            sql: """
            SELECT
                id, scope, kind, summary, evidence_json, importance,
                created_at, observed_at, expires_at, tags_json,
                related_ids_json, dedupe_key, is_pinned, attributes_json, status
            FROM memory_records
            WHERE namespace = ? AND id = ?
            LIMIT 1;
            """,
            arguments: [namespace, id]
        )
        guard let row else {
            return nil
        }
        return try makeRecord(from: row, namespace: namespace)
    }

    func archiveRecord(
        id: String,
        namespace: String,
        in db: Database
    ) throws {
        try db.execute(
            sql: """
            UPDATE memory_records
            SET status = ?
            WHERE namespace = ? AND id = ?;
            """,
            arguments: [MemoryRecordStatus.archived.rawValue, namespace, id]
        )
    }

    func deleteRecord(
        id: String,
        namespace: String,
        in db: Database
    ) throws {
        try db.execute(
            sql: "DELETE FROM memory_fts WHERE namespace = ? AND record_id = ?;",
            arguments: [namespace, id]
        )
        try db.execute(
            sql: "DELETE FROM memory_records WHERE namespace = ? AND id = ?;",
            arguments: [namespace, id]
        )
    }

    func deleteRecord(
        withDedupeKey dedupeKey: String,
        namespace: String,
        in db: Database
    ) throws {
        if let id = try String.fetchOne(
            db,
            sql: """
            SELECT id
            FROM memory_records
            WHERE namespace = ? AND dedupe_key = ?
            LIMIT 1;
            """,
            arguments: [namespace, dedupeKey]
        ) {
            try deleteRecord(id: id, namespace: namespace, in: db)
        }
    }

    func upsertRecord(
        _ record: MemoryRecord,
        in db: Database
    ) throws {
        try db.execute(
            sql: """
            INSERT OR REPLACE INTO memory_records (
                namespace, id, scope, kind, summary, evidence_json, importance,
                created_at, observed_at, expires_at, tags_json, related_ids_json,
                dedupe_key, is_pinned, attributes_json, status
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            arguments: [
                record.namespace,
                record.id,
                record.scope.rawValue,
                record.kind,
                record.summary,
                try codec.encode(record.evidence),
                record.importance,
                record.createdAt.timeIntervalSince1970,
                record.observedAt?.timeIntervalSince1970,
                record.expiresAt?.timeIntervalSince1970,
                try codec.encode(record.tags),
                try codec.encode(record.relatedIDs),
                record.dedupeKey,
                record.isPinned ? 1 : 0,
                try codec.encodeNullable(record.attributes),
                record.status.rawValue,
            ]
        )

        try db.execute(
            sql: "DELETE FROM memory_tags WHERE namespace = ? AND record_id = ?;",
            arguments: [record.namespace, record.id]
        )
        try db.execute(
            sql: "DELETE FROM memory_related_ids WHERE namespace = ? AND record_id = ?;",
            arguments: [record.namespace, record.id]
        )
        try db.execute(
            sql: "DELETE FROM memory_fts WHERE namespace = ? AND record_id = ?;",
            arguments: [record.namespace, record.id]
        )

        for tag in record.tags {
            try db.execute(
                sql: "INSERT INTO memory_tags(namespace, record_id, tag) VALUES (?, ?, ?);",
                arguments: [record.namespace, record.id, tag]
            )
        }

        for relatedID in record.relatedIDs {
            try db.execute(
                sql: """
                INSERT INTO memory_related_ids(namespace, record_id, related_id)
                VALUES (?, ?, ?);
                """,
                arguments: [record.namespace, record.id, relatedID]
            )
        }

        let ftsContent = ([record.summary] + record.evidence + record.tags + [record.kind])
            .joined(separator: " ")
        try db.execute(
            sql: "INSERT INTO memory_fts(namespace, record_id, content) VALUES (?, ?, ?);",
            arguments: [record.namespace, record.id, ftsContent]
        )
    }

    private func makeRecord(
        from row: Row,
        namespace: String
    ) throws -> MemoryRecord {
        MemoryRecord(
            id: row["id"],
            namespace: namespace,
            scope: MemoryScope(rawValue: row["scope"]),
            kind: row["kind"],
            summary: row["summary"],
            evidence: try codec.decode([String].self, from: row["evidence_json"]),
            importance: row["importance"],
            createdAt: Date(timeIntervalSince1970: row["created_at"]),
            observedAt: (row["observed_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
            expiresAt: (row["expires_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
            tags: try codec.decode([String].self, from: row["tags_json"]),
            relatedIDs: try codec.decode([String].self, from: row["related_ids_json"]),
            dedupeKey: row["dedupe_key"],
            isPinned: (row["is_pinned"] as Int64? ?? 0) == 1,
            attributes: try codec.decodeNullable(JSONValue.self, from: row["attributes_json"]),
            status: MemoryRecordStatus(rawValue: row["status"]) ?? .active
        )
    }

    private func recordExists(
        id: String,
        namespace: String,
        in db: Database
    ) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: """
            SELECT EXISTS(
                SELECT 1 FROM memory_records WHERE namespace = ? AND id = ?
            );
            """,
            arguments: [namespace, id]
        ) ?? false
    }

    private func recordExists(
        dedupeKey: String,
        namespace: String,
        in db: Database
    ) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: """
            SELECT EXISTS(
                SELECT 1 FROM memory_records WHERE namespace = ? AND dedupe_key = ?
            );
            """,
            arguments: [namespace, dedupeKey]
        ) ?? false
    }
}

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
                    if !query.includeArchived, record.status == .archived {
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
            activeRecords: records.filter { $0.status == .active }.count,
            archivedRecords: records.filter { $0.status == .archived }.count,
            countsByScope: Dictionary(grouping: records, by: \.scope).mapValues(\.count),
            countsByKind: Dictionary(grouping: records, by: \.kind).mapValues(\.count)
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
            try repository.loadRecords(namespace: namespace, in: db)
                .filter { record in
                    !record.isPinned &&
                        record.status == .active &&
                        (record.expiresAt?.compare(now) == .orderedAscending ||
                            record.expiresAt?.compare(now) == .orderedSame)
                }
                .map(\.id)
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
