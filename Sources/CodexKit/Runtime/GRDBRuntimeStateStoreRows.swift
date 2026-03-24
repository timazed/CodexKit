import Foundation
import GRDB

struct RuntimeThreadRow: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "runtime_threads"

    let threadID: String
    let createdAt: Double
    let updatedAt: Double
    let status: String
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
    let isCompactionMarker: Bool
    let isRedacted: Bool
    let encodedRecord: Data
}

struct RuntimeHistoryRowsRequest {
    let sql: String
    let arguments: StatementArguments

    func execute(in db: Database) throws -> [RuntimeHistoryRow] {
        try SQLRequest<RuntimeHistoryRow>(sql: sql, arguments: arguments).fetchAll(db)
    }
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

extension AgentHistoryItem {
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
