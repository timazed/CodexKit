import Foundation
import CodexKit
import GRDB

struct RuntimeThreadRow: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "runtime_threads"

    let threadID: String
    let createdAt: Double
    let updatedAt: Double
    let status: String
    let nextHistorySequence: Int
    let encodedThread: Data
}

struct RuntimeThreadCountQuery {
    func execute(in db: Database) throws -> Int {
        let row = try SQLRequest<Row>(
            sql: "SELECT COUNT(*) AS thread_count FROM \(RuntimeThreadRow.databaseTableName)"
        ).fetchOne(db)
        let count: Int? = row?["thread_count"]
        return count ?? 0
    }
}

struct RuntimeSummaryRow: Codable, FetchableRecord, PersistableRecord, TableRecord {
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

struct RuntimeHistoryRow: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "runtime_history_items"

    let storageID: String
    let recordID: String
    let threadID: String
    let sequenceNumber: Int
    let createdAt: Double
    let kind: String
    let turnID: String?
    let relationshipKey: String?
    let isCompactionMarker: Bool
    let isRedacted: Bool
    let messageRole: String?
    let hasStructuredOutput: Bool
    let systemEventType: String?
    let encodedRecord: Data
}

struct RuntimeHistoryWindowRow: Decodable, FetchableRecord {
    let storageID: String
    let sequenceNumber: Int
    let relationshipKey: String?
}

struct RuntimeHistoryRowsRequest {
    let sql: String
    let arguments: StatementArguments

    func execute(in db: Database) throws -> [RuntimeHistoryRow] {
        var payloadByteCount = 0
        return try execute(in: db, payloadByteCount: &payloadByteCount)
    }

    func execute(
        in db: Database,
        payloadByteCount: inout Int
    ) throws -> [RuntimeHistoryRow] {
        let cursor = try SQLRequest<RuntimeHistoryRow>(
            sql: sql,
            arguments: arguments
        ).fetchCursor(db)
        return try boundedRuntimeRows(
            cursor,
            payload: \.encodedRecord,
            name: "history query",
            payloadByteCount: &payloadByteCount
        )
    }
}

func boundedRuntimeRows<Row>(
    _ cursor: some Cursor<Row>,
    payload: (Row) -> Data,
    name: String
) throws -> [Row] {
    var payloadByteCount = 0
    return try boundedRuntimeRows(
        cursor,
        payload: payload,
        name: name,
        payloadByteCount: &payloadByteCount
    )
}

func boundedRuntimeRows<Row>(
    _ cursor: some Cursor<Row>,
    payload: (Row) -> Data,
    name: String,
    payloadByteCount: inout Int
) throws -> [Row] {
    var rows: [Row] = []
    try cursor.forEach { row in
        try AgentStoreLimitValidator.accumulateMaterializedPayload(
            payload(row),
            name: name,
            total: &payloadByteCount
        )
        rows.append(row)
    }
    return rows
}

/// Narrow row used while migrating databases whose history table predates
/// newer query-projection columns.
struct RuntimeHistoryAttachmentBackfillRow: Decodable, FetchableRecord {
    let storageID: String
    let threadID: String
    let encodedRecord: Data
}

struct RuntimeHistoryExistenceQuery {
    let sql: String
    let arguments: StatementArguments

    func execute(in db: Database) throws -> Bool {
        let row = try SQLRequest<Row>(sql: sql, arguments: arguments).fetchOne(db)
        let exists: Bool? = row?[0]
        return exists ?? false
    }
}

struct RuntimeNextHistorySequenceQuery {
    let threadID: String

    func execute(in db: Database) throws -> Int {
        guard let row = try RuntimeThreadRow.fetchOne(db, key: threadID) else {
            throw AgentRuntimeError.threadNotFound(threadID)
        }
        guard row.nextHistorySequence > 0 else {
            throw AgentStoreError.invalidInput("stored next history sequence must be positive")
        }
        return row.nextHistorySequence
    }
}

struct RuntimeStructuredOutputRow: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "runtime_structured_outputs"

    let outputID: String
    let threadID: String
    let formatName: String
    let committedAt: Double
    let encodedRecord: Data
}

struct RuntimeContextStateRow: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "runtime_context_states"

    let threadID: String
    let generation: Int
    let encodedState: Data
}

struct RuntimeAttachmentCleanupRow: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "runtime_attachment_cleanup"

    let storageKey: String
}

struct RuntimeAttachmentReferenceRow: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "runtime_attachment_references"

    let ownerType: String
    let ownerKey: String
    let threadID: String
    let storageKey: String
}

struct RuntimeStoreMetadataRow: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "runtime_store_metadata"

    let id: String
    var legacyImportCompleted: Bool
}

struct RuntimeUserVersionQuery {
    func execute(in db: Database) throws -> Int {
        let row = try SQLRequest<Row>(sql: "PRAGMA user_version;").fetchOne(db)
        return row?[0] ?? 0
    }
}

struct GRDBHistoryCursorPayload: Codable {
    let version: Int
    let threadID: String
    let sequenceNumber: Int
}
