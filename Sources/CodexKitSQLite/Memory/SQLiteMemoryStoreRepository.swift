import CodexKit
import Foundation
import GRDB

struct SQLiteMemoryStoreCodec: Sendable {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func encodeAttributes(_ value: JSONValue?) throws -> String? {
        guard let value else { return nil }
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    func decodeAttributes(_ value: String?) throws -> JSONValue? {
        guard let value else { return nil }
        guard value.utf8.prefix(MemoryStoreLimits.maximumAttributesByteCount + 1).count
            <= MemoryStoreLimits.maximumAttributesByteCount else {
            throw MemoryStoreError.invalidRecord("stored attributes exceed the supported size limit.")
        }
        return try decoder.decode(JSONValue.self, from: Data(value.utf8))
    }

    func searchTokens(from value: String?) -> [String] {
        MemoryQueryEngine.tokenize(value)
    }
}

struct SQLiteMemoryStoreRepository: Sendable {
    let codec: SQLiteMemoryStoreCodec

    struct RankedRecord: Sendable {
        let record: MemoryRecord
        let explanation: MemoryMatchExplanation
    }

    struct RankedPage: Sendable {
        let records: [RankedRecord]
        let truncated: Bool
        let nextCursor: MemoryQueryCursor?
    }

    func ensureRecordIDAvailable(
        _ id: String,
        namespace: String,
        in db: Database
    ) throws {
        let exists = try SQLiteMemoryRecord
            .filter(Column("namespace") == namespace)
            .filter(Column("id") == id)
            .fetchCount(db) > 0
        if exists {
            throw MemoryStoreError.duplicateRecordID(id)
        }
    }

    func ensureDedupeKeyAvailable(
        _ dedupeKey: String,
        namespace: String,
        in db: Database
    ) throws {
        let exists = try SQLiteMemoryRecord
            .filter(Column("namespace") == namespace)
            .filter(Column("dedupe_key") == dedupeKey)
            .fetchCount(db) > 0
        if exists {
            throw MemoryStoreError.duplicateDedupeKey(dedupeKey)
        }
    }

    func hasRecords(
        matching query: MemoryQuery,
        now: Date,
        maxCharacters: Int,
        in db: Database
    ) throws -> Bool {
        let queryTokens = MemoryQueryEngine.uniqueTokens(query.text)
        return try hasMatchingRecord(
            query: query,
            now: now,
            queryTokens: queryTokens,
            maxCharacters: maxCharacters,
            in: db
        )
    }

    func loadRecords(
        matching query: MemoryRecordListQuery,
        in db: Database
    ) throws -> [MemoryRecord] {
        var request = SQLiteMemoryRecord
            .filter(Column("namespace") == query.namespace)
        if !query.includeArchived {
            request = request.filter(Column("status") == MemoryRecordStatus.active.rawValue)
        }
        if !query.scopes.isEmpty {
            request = request.filter(query.scopes.map(\.rawValue).contains(Column("scope")))
        }
        if !query.categories.isEmpty {
            request = request.filter(query.categories.contains(Column("category")))
        }
        if let cursor = query.cursor {
            let timestamp = cursor.effectiveDate.timeIntervalSince1970
            request = request.filter(
                Column("effective_at") < timestamp ||
                    (Column("effective_at") == timestamp && Column("id") > cursor.recordID)
            )
        }
        request = request.order(Column("effective_at").desc, Column("id").asc)
        let limit = query.limit ?? MemoryStoreLimits.maximumListResultCount
        request = request.limit(limit, offset: query.offset)
        let rows = try request.fetchAll(db)
        return try makeRecords(from: rows, namespace: query.namespace, in: db)
    }

    func loadDiagnostics(
        namespace: String,
        schemaVersion: Int,
        in db: Database
    ) throws -> MemoryStoreDiagnostics {
        let totals = try SQLRequest<Row>(
            sql: """
            SELECT total_count, active_count, archived_count
            FROM memory_diagnostics
            WHERE namespace = ?
            """,
            arguments: [namespace]
        ).fetchOne(db)
        let rowLimit = MemoryStoreLimits.maximumDiagnosticDimensionValueCount + 1
        let scopeRows = try SQLRequest<Row>(
            sql: "SELECT value, record_count FROM memory_diagnostic_scopes WHERE namespace = ? LIMIT ?",
            arguments: [namespace, rowLimit]
        ).fetchAll(db)
        let categoryRows = try SQLRequest<Row>(
            sql: "SELECT value, record_count FROM memory_diagnostic_categories WHERE namespace = ? LIMIT ?",
            arguments: [namespace, rowLimit]
        ).fetchAll(db)
        guard scopeRows.count < rowLimit, categoryRows.count < rowLimit else {
            throw MemoryStoreError.invalidRecord(
                "namespace \(namespace) exceeds the diagnostics dimension limit of \(MemoryStoreLimits.maximumDiagnosticDimensionValueCount)."
            )
        }
        return MemoryStoreDiagnostics(
            namespace: namespace,
            implementation: .sqlite,
            schemaVersion: schemaVersion,
            totalRecords: totals?["total_count"] ?? 0,
            activeRecords: totals?["active_count"] ?? 0,
            archivedRecords: totals?["archived_count"] ?? 0,
            countsByScope: Dictionary(uniqueKeysWithValues: scopeRows.map { row in
                (MemoryScope(rawValue: row["value"]), row["record_count"] as Int)
            }),
            countsByCategory: Dictionary(uniqueKeysWithValues: categoryRows.map { row in
                (row["value"] as String, row["record_count"] as Int)
            })
        )
    }

    func deleteExpiredRecords(
        now: Date,
        namespace: String,
        in db: Database
    ) throws -> Int {
        try SQLiteMemoryRecord
            .filter(Column("namespace") == namespace)
            .filter(Column("status") == MemoryRecordStatus.active.rawValue)
            .filter(Column("is_pinned") == false)
            .filter(Column("expires_at") != nil)
            .filter(Column("expires_at") <= now.timeIntervalSince1970)
            .deleteAll(db)
    }

    func loadRecord(id: String, namespace: String, in db: Database) throws -> MemoryRecord? {
        try makeRecords(ids: [id], namespace: namespace, in: db).first
    }

    func archiveRecord(id: String, namespace: String, in db: Database) throws {
        try SQLiteMemoryRecord
            .filter(Column("namespace") == namespace)
            .filter(Column("id") == id)
            .updateAll(db, Column("status").set(to: MemoryRecordStatus.archived.rawValue))
    }

    func archiveRecords(ids: [String], namespace: String, in db: Database) throws {
        let uniqueIDs = Array(Set(ids))
        guard !uniqueIDs.isEmpty else { return }
        try SQLiteMemoryRecord
            .filter(Column("namespace") == namespace)
            .filter(uniqueIDs.contains(Column("id")))
            .updateAll(db, Column("status").set(to: MemoryRecordStatus.archived.rawValue))
    }

    func deleteRecord(id: String, namespace: String, in db: Database) throws {
        try SQLiteMemoryRecord
            .filter(Column("namespace") == namespace)
            .filter(Column("id") == id)
            .deleteAll(db)
    }

    func deleteRecords(ids: [String], namespace: String, in db: Database) throws {
        let uniqueIDs = Array(Set(ids))
        guard !uniqueIDs.isEmpty else { return }
        try SQLiteMemoryRecord
            .filter(Column("namespace") == namespace)
            .filter(uniqueIDs.contains(Column("id")))
            .deleteAll(db)
    }

    func deleteRecord(withDedupeKey dedupeKey: String, namespace: String, in db: Database) throws {
        let id = try String.fetchOne(
            db,
            sql: "SELECT id FROM memory_records WHERE namespace = ? AND dedupe_key = ? LIMIT 1",
            arguments: [namespace, dedupeKey]
        )
        if let id {
            try deleteRecord(id: id, namespace: namespace, in: db)
        }
    }

    func insertRecord(_ record: MemoryRecord, in db: Database) throws {
        do {
            try makeSQLiteRecord(from: record).insert(db)
        } catch {
            let detail = String(describing: error)
            if detail.contains("memory diagnostics scope limit exceeded") {
                throw MemoryStoreError.invalidRecord(
                    "namespace \(record.namespace) exceeds the diagnostics scope limit of \(MemoryStoreLimits.maximumDiagnosticDimensionValueCount)."
                )
            }
            if detail.contains("memory diagnostics category limit exceeded") {
                throw MemoryStoreError.invalidRecord(
                    "namespace \(record.namespace) exceeds the diagnostics category limit of \(MemoryStoreLimits.maximumDiagnosticDimensionValueCount)."
                )
            }
            throw error
        }
        for (ordinal, value) in record.evidence.enumerated() {
            try SQLiteMemoryEvidence(
                namespace: record.namespace,
                recordID: record.id,
                ordinal: ordinal,
                value: value
            ).insert(db)
        }
        for (ordinal, value) in record.tags.enumerated() {
            try SQLiteMemoryTag(
                namespace: record.namespace,
                recordID: record.id,
                ordinal: ordinal,
                value: value
            ).insert(db)
        }
        for (ordinal, value) in record.relatedIDs.enumerated() {
            try SQLiteMemoryRelatedID(
                namespace: record.namespace,
                recordID: record.id,
                ordinal: ordinal,
                value: value
            ).insert(db)
        }
        let searchableText = ([record.summary, record.category] + record.evidence + record.tags)
            .joined(separator: " ")
        for value in codec.searchTokens(from: searchableText) {
            try SQLiteMemorySearchToken(
                namespace: record.namespace,
                recordID: record.id,
                value: value
            ).insert(db)
        }
    }

    func makeRecord(
        from row: SQLiteMemoryRecord,
        in db: Database,
        includeAttributes: Bool = true
    ) throws -> MemoryRecord {
        try makeRecords(
            from: [row],
            namespace: row.namespace,
            in: db,
            includeAttributes: includeAttributes
        )[0]
    }

    private func makeSQLiteRecord(from record: MemoryRecord) throws -> SQLiteMemoryRecord {
        SQLiteMemoryRecord(
            namespace: record.namespace,
            id: record.id,
            recordOrder: MemoryQueryEngine.recordOrder(for: record.id),
            scope: record.scope.rawValue,
            category: record.category,
            summary: record.summary,
            importance: record.importance,
            createdAt: record.createdAt.timeIntervalSince1970,
            observedAt: record.observedAt?.timeIntervalSince1970,
            effectiveAt: record.effectiveDate.timeIntervalSince1970,
            expiresAt: record.expiresAt?.timeIntervalSince1970,
            dedupeKey: record.dedupeKey,
            isPinned: record.isPinned,
            attributesJSON: try codec.encodeAttributes(record.attributes),
            status: record.status.rawValue,
            renderedCharacterCount: MemoryQueryEngine.renderedCharacterCount(for: record)
        )
    }

    func makeRecords(
        ids: [String],
        namespace: String,
        in db: Database
    ) throws -> [MemoryRecord] {
        guard !ids.isEmpty else { return [] }
        let rows = try SQLiteMemoryRecord
            .filter(Column("namespace") == namespace)
            .filter(ids.contains(Column("id")))
            .fetchAll(db)
        let records = try makeRecords(from: rows, namespace: namespace, in: db)
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        return ids.compactMap { byID[$0] }
    }

    func makeRecords(
        from rows: [SQLiteMemoryRecord],
        namespace: String,
        in db: Database,
        includeAttributes: Bool = true,
        validateProjections: Bool = true
    ) throws -> [MemoryRecord] {
        guard !rows.isEmpty else { return [] }
        guard rows.count <= MemoryStoreLimits.maximumListResultCount else {
            throw MemoryStoreError.invalidRecord(
                "stored memory query exceeded the bounded materialization limit."
            )
        }
        let ids = rows.map(\.id)
        let evidenceLimit = try boundedChildRowLimit(
            parentCount: rows.count,
            maximumPerParent: MemoryStoreLimits.maximumEvidenceCount
        )
        let evidence = try SQLiteMemoryEvidence
            .filter(Column("namespace") == namespace)
            .filter(ids.contains(Column("record_id")))
            .order(Column("record_id").asc, Column("ordinal").asc)
            .limit(evidenceLimit)
            .fetchAll(db)
        let tagLimit = try boundedChildRowLimit(
            parentCount: rows.count,
            maximumPerParent: MemoryStoreLimits.maximumTagCount
        )
        let tags = try SQLiteMemoryTag
            .filter(Column("namespace") == namespace)
            .filter(ids.contains(Column("record_id")))
            .order(Column("record_id").asc, Column("ordinal").asc)
            .limit(tagLimit)
            .fetchAll(db)
        let relatedIDLimit = try boundedChildRowLimit(
            parentCount: rows.count,
            maximumPerParent: MemoryStoreLimits.maximumRelatedIDCount
        )
        let relatedIDs = try SQLiteMemoryRelatedID
            .filter(Column("namespace") == namespace)
            .filter(ids.contains(Column("record_id")))
            .order(Column("record_id").asc, Column("ordinal").asc)
            .limit(relatedIDLimit)
            .fetchAll(db)
        guard evidence.count < evidenceLimit,
              tags.count < tagLimit,
              relatedIDs.count < relatedIDLimit else {
            throw MemoryStoreError.invalidRecord(
                "stored memory collections exceed their bounded limits."
            )
        }
        let evidenceByID = Dictionary(grouping: evidence, by: \.recordID)
        let tagsByID = Dictionary(grouping: tags, by: \.recordID)
        let relatedByID = Dictionary(grouping: relatedIDs, by: \.recordID)
        return try rows.map { row in
            guard let status = MemoryRecordStatus(rawValue: row.status) else {
                throw MemoryStoreError.invalidRecord(
                    "stored memory status is invalid."
                )
            }
            let record = MemoryRecord(
                id: row.id,
                namespace: row.namespace,
                scope: MemoryScope(rawValue: row.scope),
                category: row.category,
                summary: row.summary,
                evidence: evidenceByID[row.id, default: []].map(\.value),
                importance: row.importance,
                createdAt: Date(timeIntervalSince1970: row.createdAt),
                observedAt: row.observedAt.map(Date.init(timeIntervalSince1970:)),
                expiresAt: row.expiresAt.map(Date.init(timeIntervalSince1970:)),
                tags: tagsByID[row.id, default: []].map(\.value),
                relatedIDs: relatedByID[row.id, default: []].map(\.value),
                dedupeKey: row.dedupeKey,
                isPinned: row.isPinned,
                attributes: includeAttributes ? try codec.decodeAttributes(row.attributesJSON) : nil,
                status: status
            )
            try MemoryQueryEngine.validate(record)
            guard !validateProjections || (
                row.namespace == namespace &&
                    row.recordOrder == MemoryQueryEngine.recordOrder(for: record.id) &&
                    row.effectiveAt == record.effectiveDate.timeIntervalSince1970 &&
                    row.renderedCharacterCount == MemoryQueryEngine.renderedCharacterCount(for: record)
            ) else {
                throw MemoryStoreError.invalidRecord(
                    "stored memory payload does not match its indexed projections."
                )
            }
            return record
        }
    }

    private func boundedChildRowLimit(
        parentCount: Int,
        maximumPerParent: Int
    ) throws -> Int {
        let (product, overflow) = parentCount.multipliedReportingOverflow(
            by: maximumPerParent
        )
        let (limit, additionOverflow) = product.addingReportingOverflow(1)
        guard !overflow, !additionOverflow else {
            throw MemoryStoreError.invalidRecord(
                "stored memory collection limit overflowed."
            )
        }
        return limit
    }

}

struct SQLiteMemoryRecord: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "memory_records"

    let namespace: String
    let id: String
    let recordOrder: Int64
    let scope: String
    let category: String
    let summary: String
    let importance: Double
    let createdAt: Double
    let observedAt: Double?
    let effectiveAt: Double
    let expiresAt: Double?
    let dedupeKey: String?
    let isPinned: Bool
    let attributesJSON: String?
    let status: String
    let renderedCharacterCount: Int

    enum CodingKeys: String, CodingKey {
        case namespace, id, scope, category, summary, importance, status
        case recordOrder = "record_order"
        case createdAt = "created_at"
        case observedAt = "observed_at"
        case effectiveAt = "effective_at"
        case expiresAt = "expires_at"
        case dedupeKey = "dedupe_key"
        case isPinned = "is_pinned"
        case attributesJSON = "attributes_json"
        case renderedCharacterCount = "rendered_character_count"
    }
}

struct SQLiteMemoryEvidence: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "memory_evidence"
    let namespace: String
    let recordID: String
    let ordinal: Int
    let value: String

    enum CodingKeys: String, CodingKey {
        case namespace, ordinal, value
        case recordID = "record_id"
    }
}

struct SQLiteMemoryTag: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "memory_tags"
    let namespace: String
    let recordID: String
    let ordinal: Int
    let value: String

    enum CodingKeys: String, CodingKey {
        case namespace, ordinal, value
        case recordID = "record_id"
    }
}

struct SQLiteMemoryRelatedID: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "memory_related_ids"
    let namespace: String
    let recordID: String
    let ordinal: Int
    let value: String

    enum CodingKeys: String, CodingKey {
        case namespace, ordinal, value
        case recordID = "record_id"
    }
}

struct SQLiteMemorySearchToken: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "memory_search_tokens"
    let namespace: String
    let recordID: String
    let value: String

    enum CodingKeys: String, CodingKey {
        case namespace, value
        case recordID = "record_id"
    }
}
