import Foundation
import GRDB

struct SQLiteMemoryStoreCodec: Sendable {
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

struct SQLiteMemoryStoreRepository: Sendable {
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
        let rows = try MemoryRecordDatabaseRow
            .filter(Column("namespace") == namespace)
            .fetchAll(db)

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

        let rows = try MemoryFTSScoreRowsRequest(
            namespace: namespace,
            matchQuery: matchQuery
        ).execute(in: db)

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
        let row = try MemoryRecordDatabaseRow
            .filter(Column("namespace") == namespace)
            .filter(Column("id") == id)
            .fetchOne(db)
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
        try MemoryRecordDatabaseRow
            .filter(Column("namespace") == namespace)
            .filter(Column("id") == id)
            .updateAll(db, Column("status").set(to: MemoryRecordStatus.archived.rawValue))
    }

    func deleteRecord(
        id: String,
        namespace: String,
        in db: Database
    ) throws {
        try MemoryFTSRow
            .filter(Column("namespace") == namespace)
            .filter(Column("record_id") == id)
            .deleteAll(db)
        try MemoryRecordDatabaseRow
            .filter(Column("namespace") == namespace)
            .filter(Column("id") == id)
            .deleteAll(db)
    }

    func deleteRecord(
        withDedupeKey dedupeKey: String,
        namespace: String,
        in db: Database
    ) throws {
        if let row = try MemoryRecordRow
            .filter(Column("namespace") == namespace)
            .filter(Column("dedupe_key") == dedupeKey)
            .fetchOne(db) {
            try deleteRecord(id: row.id, namespace: namespace, in: db)
        }
    }

    func upsertRecord(
        _ record: MemoryRecord,
        in db: Database
    ) throws {
        try MemoryRecordDatabaseRow
            .filter(Column("namespace") == record.namespace)
            .filter(Column("id") == record.id)
            .deleteAll(db)
        try makeDatabaseRow(from: record).insert(db)

        try MemoryTagRow
            .filter(Column("namespace") == record.namespace)
            .filter(Column("record_id") == record.id)
            .deleteAll(db)
        try MemoryRelatedIDRow
            .filter(Column("namespace") == record.namespace)
            .filter(Column("record_id") == record.id)
            .deleteAll(db)
        try MemoryFTSRow
            .filter(Column("namespace") == record.namespace)
            .filter(Column("record_id") == record.id)
            .deleteAll(db)

        for tag in record.tags {
            try MemoryTagRow(
                namespace: record.namespace,
                recordID: record.id,
                tag: tag
            ).insert(db)
        }

        for relatedID in record.relatedIDs {
            try MemoryRelatedIDRow(
                namespace: record.namespace,
                recordID: record.id,
                relatedID: relatedID
            ).insert(db)
        }

        let ftsContent = ([record.summary] + record.evidence + record.tags + [record.category])
            .joined(separator: " ")
        try MemoryFTSRow(
            namespace: record.namespace,
            recordID: record.id,
            content: ftsContent
        ).insert(db)
    }

    private func makeDatabaseRow(from record: MemoryRecord) throws -> MemoryRecordDatabaseRow {
        try MemoryRecordDatabaseRow(
            namespace: record.namespace,
            id: record.id,
            scope: record.scope.rawValue,
            kind: record.category,
            summary: record.summary,
            evidenceJSON: codec.encode(record.evidence),
            importance: record.importance,
            createdAt: record.createdAt.timeIntervalSince1970,
            observedAt: record.observedAt?.timeIntervalSince1970,
            expiresAt: record.expiresAt?.timeIntervalSince1970,
            tagsJSON: codec.encode(record.tags),
            relatedIDsJSON: codec.encode(record.relatedIDs),
            dedupeKey: record.dedupeKey,
            isPinned: record.isPinned,
            attributesJSON: codec.encodeNullable(record.attributes),
            status: record.status.rawValue
        )
    }

    private func makeRecord(
        from row: MemoryRecordDatabaseRow,
        namespace: String
    ) throws -> MemoryRecord {
        MemoryRecord(
            id: row.id,
            namespace: namespace,
            scope: MemoryScope(rawValue: row.scope),
            category: row.kind,
            summary: row.summary,
            evidence: try codec.decode([String].self, from: row.evidenceJSON),
            importance: row.importance,
            createdAt: Date(timeIntervalSince1970: row.createdAt),
            observedAt: row.observedAt.map(Date.init(timeIntervalSince1970:)),
            expiresAt: row.expiresAt.map(Date.init(timeIntervalSince1970:)),
            tags: try codec.decode([String].self, from: row.tagsJSON),
            relatedIDs: try codec.decode([String].self, from: row.relatedIDsJSON),
            dedupeKey: row.dedupeKey,
            isPinned: row.isPinned,
            attributes: try codec.decodeNullable(JSONValue.self, from: row.attributesJSON),
            status: MemoryRecordStatus(rawValue: row.status) ?? .active
        )
    }

    private func recordExists(
        id: String,
        namespace: String,
        in db: Database
    ) throws -> Bool {
        try MemoryRecordRow
            .filter(Column("namespace") == namespace)
            .filter(Column("id") == id)
            .fetchCount(db) > 0
    }

    private func recordExists(
        dedupeKey: String,
        namespace: String,
        in db: Database
    ) throws -> Bool {
        try MemoryRecordRow
            .filter(Column("namespace") == namespace)
            .filter(Column("dedupe_key") == dedupeKey)
            .fetchCount(db) > 0
    }
}

struct MemoryFTSScoreRowsRequest: Sendable {
    let namespace: String
    let matchQuery: String

    func execute(in db: Database) throws -> [Row] {
        // FTS5 MATCH and bm25() are much clearer and more direct in raw SQL than in GRDB's query interface.
        try SQLRequest<Row>(
            sql: """
            SELECT record_id, bm25(memory_fts) AS score
            FROM memory_fts
            WHERE namespace = ? AND memory_fts MATCH ?;
            """,
            arguments: [namespace, matchQuery]
        ).fetchAll(db)
    }
}

struct MemoryRecordRow: FetchableRecord, TableRecord {
    static let databaseTableName = "memory_records"

    let id: String
    let scope: String
    let kind: String
    let summary: String
    let evidenceJSON: String
    let importance: Double
    let createdAt: Double
    let observedAt: Double?
    let expiresAt: Double?
    let tagsJSON: String
    let relatedIDsJSON: String
    let dedupeKey: String?
    let isPinned: Bool
    let attributesJSON: String?
    let status: String

    init(row: Row) {
        id = row["id"]
        scope = row["scope"]
        kind = row["kind"]
        summary = row["summary"]
        evidenceJSON = row["evidence_json"]
        importance = row["importance"]
        createdAt = row["created_at"]
        observedAt = row["observed_at"]
        expiresAt = row["expires_at"]
        tagsJSON = row["tags_json"]
        relatedIDsJSON = row["related_ids_json"]
        dedupeKey = row["dedupe_key"]
        isPinned = row["is_pinned"] as Bool? ?? false
        attributesJSON = row["attributes_json"]
        status = row["status"]
    }
}

struct MemoryRecordDatabaseRow: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "memory_records"

    let namespace: String
    let id: String
    let scope: String
    let kind: String
    let summary: String
    let evidenceJSON: String
    let importance: Double
    let createdAt: Double
    let observedAt: Double?
    let expiresAt: Double?
    let tagsJSON: String
    let relatedIDsJSON: String
    let dedupeKey: String?
    let isPinned: Bool
    let attributesJSON: String?
    let status: String

    enum CodingKeys: String, CodingKey {
        case namespace
        case id
        case scope
        case kind
        case summary
        case evidenceJSON = "evidence_json"
        case importance
        case createdAt = "created_at"
        case observedAt = "observed_at"
        case expiresAt = "expires_at"
        case tagsJSON = "tags_json"
        case relatedIDsJSON = "related_ids_json"
        case dedupeKey = "dedupe_key"
        case isPinned = "is_pinned"
        case attributesJSON = "attributes_json"
        case status
    }
}

struct MemoryTagRow: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "memory_tags"

    let namespace: String
    let recordID: String
    let tag: String

    enum CodingKeys: String, CodingKey {
        case namespace
        case recordID = "record_id"
        case tag
    }
}

struct MemoryRelatedIDRow: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "memory_related_ids"

    let namespace: String
    let recordID: String
    let relatedID: String

    enum CodingKeys: String, CodingKey {
        case namespace
        case recordID = "record_id"
        case relatedID = "related_id"
    }
}

struct MemoryFTSRow: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "memory_fts"

    let namespace: String
    let recordID: String
    let content: String

    enum CodingKeys: String, CodingKey {
        case namespace
        case recordID = "record_id"
        case content
    }
}
