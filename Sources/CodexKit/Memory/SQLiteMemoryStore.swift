import Foundation
import SQLite3

public actor SQLiteMemoryStore: MemoryStoring {
    private let url: URL
    private nonisolated(unsafe) var database: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(url: URL) throws {
        self.url = url
        self.database = try Self.openDatabase(at: url)
        try Self.createSchemaIfNeeded(in: database)
    }

    deinit {
        if let database {
            sqlite3_close(database)
        }
    }

    public func put(_ record: MemoryRecord) async throws {
        try MemoryQueryEngine.validateNamespace(record.namespace)
        try transaction {
            try ensureRecordIDAvailable(record.id, namespace: record.namespace)
            if let dedupeKey = record.dedupeKey {
                try ensureDedupeKeyAvailable(dedupeKey, namespace: record.namespace)
            }
            try upsertRecord(record)
        }
    }

    public func putMany(_ records: [MemoryRecord]) async throws {
        try transaction {
            for record in records {
                try MemoryQueryEngine.validateNamespace(record.namespace)
                try ensureRecordIDAvailable(record.id, namespace: record.namespace)
                if let dedupeKey = record.dedupeKey {
                    try ensureDedupeKeyAvailable(dedupeKey, namespace: record.namespace)
                }
                try upsertRecord(record)
            }
        }
    }

    public func upsert(_ record: MemoryRecord, dedupeKey: String) async throws {
        try MemoryQueryEngine.validateNamespace(record.namespace)
        try transaction {
            try deleteRecord(withDedupeKey: dedupeKey, namespace: record.namespace)
            try deleteRecord(id: record.id, namespace: record.namespace)
            var updatedRecord = record
            updatedRecord.dedupeKey = dedupeKey
            try upsertRecord(updatedRecord)
        }
    }

    public func query(_ query: MemoryQuery) async throws -> MemoryQueryResult {
        try MemoryQueryEngine.validateNamespace(query.namespace)
        let records = try loadRecords(namespace: query.namespace)
        let rawScores = try loadFTSRawScores(
            namespace: query.namespace,
            queryText: query.text
        )

        let candidates = records.map { record in
            MemoryQueryEngine.Candidate(
                record: record,
                rawTextScore: rawScores[record.id]
            )
        }

        return try MemoryQueryEngine.evaluate(
            candidates: candidates,
            query: query
        )
    }

    public func compact(_ request: MemoryCompactionRequest) async throws {
        try MemoryQueryEngine.validateNamespace(request.replacement.namespace)
        try transaction {
            try ensureRecordIDAvailable(request.replacement.id, namespace: request.replacement.namespace)
            if let dedupeKey = request.replacement.dedupeKey {
                try ensureDedupeKeyAvailable(dedupeKey, namespace: request.replacement.namespace)
            }
            try upsertRecord(request.replacement)
            for sourceID in request.sourceIDs {
                try archiveRecord(id: sourceID, namespace: request.replacement.namespace)
            }
        }
    }

    public func archive(ids: [String], namespace: String) async throws {
        try MemoryQueryEngine.validateNamespace(namespace)
        try transaction {
            for id in ids {
                try archiveRecord(id: id, namespace: namespace)
            }
        }
    }

    public func delete(ids: [String], namespace: String) async throws {
        try MemoryQueryEngine.validateNamespace(namespace)
        try transaction {
            for id in ids {
                try deleteRecord(id: id, namespace: namespace)
            }
        }
    }

    @discardableResult
    public func pruneExpired(
        now: Date,
        namespace: String
    ) async throws -> Int {
        try MemoryQueryEngine.validateNamespace(namespace)
        let expiredIDs = try loadRecords(namespace: namespace)
            .filter { record in
                !record.isPinned &&
                    record.status == .active &&
                    (record.expiresAt?.compare(now) == .orderedAscending ||
                        record.expiresAt?.compare(now) == .orderedSame)
            }
            .map(\.id)

        try transaction {
            for id in expiredIDs {
                try deleteRecord(id: id, namespace: namespace)
            }
        }
        return expiredIDs.count
    }

    private static func openDatabase(at url: URL) throws -> OpaquePointer {
        let directory = url.deletingLastPathComponent()
        if !directory.path.isEmpty {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }

        var database: OpaquePointer?
        let result = sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let database else {
            throw sqliteError(
                database,
                message: "Failed to open SQLite memory store."
            )
        }
        sqlite3_exec(database, "PRAGMA foreign_keys = ON;", nil, nil, nil)
        return database
    }

    private static func createSchemaIfNeeded(in database: OpaquePointer?) throws {
        let schema = """
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
        CREATE UNIQUE INDEX IF NOT EXISTS memory_records_namespace_dedupe
            ON memory_records(namespace, dedupe_key)
            WHERE dedupe_key IS NOT NULL;
        CREATE INDEX IF NOT EXISTS memory_records_namespace_scope
            ON memory_records(namespace, scope);
        CREATE INDEX IF NOT EXISTS memory_records_namespace_kind
            ON memory_records(namespace, kind);
        CREATE INDEX IF NOT EXISTS memory_records_namespace_status
            ON memory_records(namespace, status);
        CREATE TABLE IF NOT EXISTS memory_tags (
            namespace TEXT NOT NULL,
            record_id TEXT NOT NULL,
            tag TEXT NOT NULL,
            FOREIGN KEY(namespace, record_id)
                REFERENCES memory_records(namespace, id)
                ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS memory_tags_lookup
            ON memory_tags(namespace, tag, record_id);
        CREATE TABLE IF NOT EXISTS memory_related_ids (
            namespace TEXT NOT NULL,
            record_id TEXT NOT NULL,
            related_id TEXT NOT NULL,
            FOREIGN KEY(namespace, record_id)
                REFERENCES memory_records(namespace, id)
                ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS memory_related_lookup
            ON memory_related_ids(namespace, related_id, record_id);
        CREATE VIRTUAL TABLE IF NOT EXISTS memory_fts
            USING fts5(namespace UNINDEXED, record_id UNINDEXED, content);
        """
        try execSQL(database, schema)
    }

    private func ensureRecordIDAvailable(
        _ id: String,
        namespace: String
    ) throws {
        if try recordExists(id: id, namespace: namespace) {
            throw MemoryStoreError.duplicateRecordID(id)
        }
    }

    private func ensureDedupeKeyAvailable(
        _ dedupeKey: String,
        namespace: String
    ) throws {
        if try recordExists(dedupeKey: dedupeKey, namespace: namespace) {
            throw MemoryStoreError.duplicateDedupeKey(dedupeKey)
        }
    }

    private func loadRecords(namespace: String) throws -> [MemoryRecord] {
        let sql = """
        SELECT
            id, scope, kind, summary, evidence_json, importance,
            created_at, observed_at, expires_at, tags_json,
            related_ids_json, dedupe_key, is_pinned, attributes_json, status
        FROM memory_records
        WHERE namespace = ?;
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bindText(namespace, to: statement, index: 1)

        var records: [MemoryRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = try columnText(statement, index: 0)
            let scope = MemoryScope(rawValue: try columnText(statement, index: 1))
            let kind = try columnText(statement, index: 2)
            let summary = try columnText(statement, index: 3)
            let evidence = try decodeJSON([String].self, from: try columnText(statement, index: 4))
            let importance = sqlite3_column_double(statement, 5)
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 6))
            let observedAt = sqlite3_column_type(statement, 7) == SQLITE_NULL
                ? nil
                : Date(timeIntervalSince1970: sqlite3_column_double(statement, 7))
            let expiresAt = sqlite3_column_type(statement, 8) == SQLITE_NULL
                ? nil
                : Date(timeIntervalSince1970: sqlite3_column_double(statement, 8))
            let tags = try decodeJSON([String].self, from: try columnText(statement, index: 9))
            let relatedIDs = try decodeJSON([String].self, from: try columnText(statement, index: 10))
            let dedupeKey = sqlite3_column_type(statement, 11) == SQLITE_NULL ? nil : try columnText(statement, index: 11)
            let isPinned = sqlite3_column_int(statement, 12) == 1
            let attributes = sqlite3_column_type(statement, 13) == SQLITE_NULL
                ? nil
                : try decodeJSON(JSONValue.self, from: try columnText(statement, index: 13))
            let status = MemoryRecordStatus(rawValue: try columnText(statement, index: 14)) ?? .active

            records.append(
                MemoryRecord(
                    id: id,
                    namespace: namespace,
                    scope: scope,
                    kind: kind,
                    summary: summary,
                    evidence: evidence,
                    importance: importance,
                    createdAt: createdAt,
                    observedAt: observedAt,
                    expiresAt: expiresAt,
                    tags: tags,
                    relatedIDs: relatedIDs,
                    dedupeKey: dedupeKey,
                    isPinned: isPinned,
                    attributes: attributes,
                    status: status
                )
            )
        }

        return records
    }

    private func loadFTSRawScores(
        namespace: String,
        queryText: String?
    ) throws -> [String: Double] {
        let matchQuery = ftsQuery(from: queryText)
        guard !matchQuery.isEmpty else {
            return [:]
        }

        let sql = """
        SELECT record_id, bm25(memory_fts)
        FROM memory_fts
        WHERE namespace = ? AND memory_fts MATCH ?;
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bindText(namespace, to: statement, index: 1)
        try bindText(matchQuery, to: statement, index: 2)

        var scores: [String: Double] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let recordID = try columnText(statement, index: 0)
            let score = sqlite3_column_double(statement, 1)
            scores[recordID] = score
        }
        return scores
    }

    private func recordExists(
        id: String,
        namespace: String
    ) throws -> Bool {
        let sql = "SELECT 1 FROM memory_records WHERE namespace = ? AND id = ? LIMIT 1;"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bindText(namespace, to: statement, index: 1)
        try bindText(id, to: statement, index: 2)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private func recordExists(
        dedupeKey: String,
        namespace: String
    ) throws -> Bool {
        let sql = "SELECT 1 FROM memory_records WHERE namespace = ? AND dedupe_key = ? LIMIT 1;"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bindText(namespace, to: statement, index: 1)
        try bindText(dedupeKey, to: statement, index: 2)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private func archiveRecord(
        id: String,
        namespace: String
    ) throws {
        let sql = """
        UPDATE memory_records
        SET status = ?
        WHERE namespace = ? AND id = ?;
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bindText(MemoryRecordStatus.archived.rawValue, to: statement, index: 1)
        try bindText(namespace, to: statement, index: 2)
        try bindText(id, to: statement, index: 3)
        try step(statement)
    }

    private func deleteRecord(
        id: String,
        namespace: String
    ) throws {
        try exec(
            "DELETE FROM memory_fts WHERE namespace = ? AND record_id = ?;",
            bindings: [.text(namespace), .text(id)]
        )
        try exec(
            "DELETE FROM memory_related_ids WHERE namespace = ? AND record_id = ?;",
            bindings: [.text(namespace), .text(id)]
        )
        try exec(
            "DELETE FROM memory_tags WHERE namespace = ? AND record_id = ?;",
            bindings: [.text(namespace), .text(id)]
        )
        try exec(
            "DELETE FROM memory_records WHERE namespace = ? AND id = ?;",
            bindings: [.text(namespace), .text(id)]
        )
    }

    private func deleteRecord(
        withDedupeKey dedupeKey: String,
        namespace: String
    ) throws {
        let statement = try prepare(
            "SELECT id FROM memory_records WHERE namespace = ? AND dedupe_key = ? LIMIT 1;"
        )
        defer { sqlite3_finalize(statement) }
        try bindText(namespace, to: statement, index: 1)
        try bindText(dedupeKey, to: statement, index: 2)
        if sqlite3_step(statement) == SQLITE_ROW {
            let id = try columnText(statement, index: 0)
            try deleteRecord(id: id, namespace: namespace)
        }
    }

    private func upsertRecord(_ record: MemoryRecord) throws {
        let sql = """
        INSERT OR REPLACE INTO memory_records (
            namespace, id, scope, kind, summary, evidence_json, importance,
            created_at, observed_at, expires_at, tags_json, related_ids_json,
            dedupe_key, is_pinned, attributes_json, status
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        try bindText(record.namespace, to: statement, index: 1)
        try bindText(record.id, to: statement, index: 2)
        try bindText(record.scope.rawValue, to: statement, index: 3)
        try bindText(record.kind, to: statement, index: 4)
        try bindText(record.summary, to: statement, index: 5)
        try bindText(try encodeJSON(record.evidence), to: statement, index: 6)
        sqlite3_bind_double(statement, 7, record.importance)
        sqlite3_bind_double(statement, 8, record.createdAt.timeIntervalSince1970)
        if let observedAt = record.observedAt {
            sqlite3_bind_double(statement, 9, observedAt.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(statement, 9)
        }
        if let expiresAt = record.expiresAt {
            sqlite3_bind_double(statement, 10, expiresAt.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(statement, 10)
        }
        try bindText(try encodeJSON(record.tags), to: statement, index: 11)
        try bindText(try encodeJSON(record.relatedIDs), to: statement, index: 12)
        if let dedupeKey = record.dedupeKey {
            try bindText(dedupeKey, to: statement, index: 13)
        } else {
            sqlite3_bind_null(statement, 13)
        }
        sqlite3_bind_int(statement, 14, record.isPinned ? 1 : 0)
        if let attributes = record.attributes {
            try bindText(try encodeJSON(attributes), to: statement, index: 15)
        } else {
            sqlite3_bind_null(statement, 15)
        }
        try bindText(record.status.rawValue, to: statement, index: 16)
        try step(statement)

        try exec(
            "DELETE FROM memory_tags WHERE namespace = ? AND record_id = ?;",
            bindings: [.text(record.namespace), .text(record.id)]
        )
        try exec(
            "DELETE FROM memory_related_ids WHERE namespace = ? AND record_id = ?;",
            bindings: [.text(record.namespace), .text(record.id)]
        )
        try exec(
            "DELETE FROM memory_fts WHERE namespace = ? AND record_id = ?;",
            bindings: [.text(record.namespace), .text(record.id)]
        )

        for tag in record.tags {
            try exec(
                "INSERT INTO memory_tags(namespace, record_id, tag) VALUES (?, ?, ?);",
                bindings: [.text(record.namespace), .text(record.id), .text(tag)]
            )
        }

        for relatedID in record.relatedIDs {
            try exec(
                "INSERT INTO memory_related_ids(namespace, record_id, related_id) VALUES (?, ?, ?);",
                bindings: [.text(record.namespace), .text(record.id), .text(relatedID)]
            )
        }

        let ftsContent = ([record.summary] + record.evidence + record.tags + [record.kind]).joined(separator: " ")
        try exec(
            "INSERT INTO memory_fts(namespace, record_id, content) VALUES (?, ?, ?);",
            bindings: [.text(record.namespace), .text(record.id), .text(ftsContent)]
        )
    }

    private func transaction(_ operation: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE;")
        do {
            try operation()
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        guard let database else {
            throw sqliteError(message: "SQLite database is unavailable.")
        }
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard result == SQLITE_OK else {
            throw sqliteError(message: "Failed to prepare SQLite statement.")
        }
        return statement
    }

    private func exec(
        _ sql: String,
        bindings: [SQLiteBinding] = []
    ) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        for (index, binding) in bindings.enumerated() {
            try bind(binding, to: statement, index: Int32(index + 1))
        }

        try step(statement)
    }

    private func step(_ statement: OpaquePointer?) throws {
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw sqliteError(message: "SQLite step failed.")
        }
    }

    private func bind(
        _ binding: SQLiteBinding,
        to statement: OpaquePointer?,
        index: Int32
    ) throws {
        switch binding {
        case let .text(value):
            try bindText(value, to: statement, index: index)
        case let .double(value):
            sqlite3_bind_double(statement, index, value)
        case .null:
            sqlite3_bind_null(statement, index)
        }
    }

    private func bindText(
        _ value: String,
        to statement: OpaquePointer?,
        index: Int32
    ) throws {
        let result = sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
        guard result == SQLITE_OK else {
            throw sqliteError(message: "Failed to bind SQLite text value.")
        }
    }

    private func columnText(
        _ statement: OpaquePointer?,
        index: Int32
    ) throws -> String {
        guard let cString = sqlite3_column_text(statement, index) else {
            throw sqliteError(message: "SQLite column was unexpectedly null.")
        }
        return String(cString: cString)
    }

    private func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    private func decodeJSON<T: Decodable>(
        _ type: T.Type,
        from string: String
    ) throws -> T {
        try decoder.decode(type, from: Data(string.utf8))
    }

    private func ftsQuery(from value: String?) -> String {
        let tokens = MemoryQueryEngine.tokenize(value)
        guard !tokens.isEmpty else {
            return ""
        }
        return tokens.joined(separator: " OR ")
    }

    private static func sqliteError(
        _ database: OpaquePointer?,
        message: String
    ) -> NSError {
        let detail = if let database, let messagePointer = sqlite3_errmsg(database) {
            String(cString: messagePointer)
        } else {
            "Unknown SQLite error"
        }

        return NSError(
            domain: "CodexKit.SQLiteMemoryStore",
            code: Int(sqlite3_errcode(database)),
            userInfo: [NSLocalizedDescriptionKey: "\(message) \(detail)"]
        )
    }

    private func sqliteError(message: String) -> NSError {
        Self.sqliteError(database, message: message)
    }
}

private enum SQLiteBinding {
    case text(String)
    case double(Double)
    case null
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private func execSQL(
    _ database: OpaquePointer?,
    _ sql: String
) throws {
    var errorPointer: UnsafeMutablePointer<CChar>?
    let result = sqlite3_exec(database, sql, nil, nil, &errorPointer)
    guard result == SQLITE_OK else {
        let detail = errorPointer.map { String(cString: $0) } ?? "Unknown SQLite error"
        sqlite3_free(errorPointer)
        throw NSError(
            domain: "CodexKit.SQLiteMemoryStore",
            code: Int(result),
            userInfo: [NSLocalizedDescriptionKey: detail]
        )
    }
}
