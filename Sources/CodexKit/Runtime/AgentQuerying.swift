import Foundation

public enum AgentLogicalSchemaVersion: Int, Sendable, Codable, Hashable {
    case v1 = 1
}

public struct AgentStoreCapabilities: Sendable, Hashable, Codable {
    public var supportsPushdownQueries: Bool
    public var supportsCrossThreadQueries: Bool
    public var supportsSorting: Bool
    public var supportsFiltering: Bool
    public var supportsMigrations: Bool

    public init(
        supportsPushdownQueries: Bool,
        supportsCrossThreadQueries: Bool,
        supportsSorting: Bool,
        supportsFiltering: Bool,
        supportsMigrations: Bool
    ) {
        self.supportsPushdownQueries = supportsPushdownQueries
        self.supportsCrossThreadQueries = supportsCrossThreadQueries
        self.supportsSorting = supportsSorting
        self.supportsFiltering = supportsFiltering
        self.supportsMigrations = supportsMigrations
    }
}

public struct AgentStoreMetadata: Sendable, Hashable, Codable {
    public let logicalSchemaVersion: AgentLogicalSchemaVersion
    public let storeSchemaVersion: Int
    public let capabilities: AgentStoreCapabilities
    public let storeKind: String

    public init(
        logicalSchemaVersion: AgentLogicalSchemaVersion,
        storeSchemaVersion: Int,
        capabilities: AgentStoreCapabilities,
        storeKind: String
    ) {
        self.logicalSchemaVersion = logicalSchemaVersion
        self.storeSchemaVersion = storeSchemaVersion
        self.capabilities = capabilities
        self.storeKind = storeKind
    }
}

public enum AgentStoreError: Error, Sendable {
    case incompatibleLogicalSchema(found: Int, supported: [Int])
    case migrationRequired(from: Int, to: Int)
    case migrationFailed(String)
    case queryNotSupported(String)
}

public protocol AgentRuntimeQueryable: Sendable {
    func execute<Query: AgentQuerySpec>(_ query: Query) async throws -> Query.Result
}

public protocol AgentQuerySpec: Sendable {
    associatedtype Result: Sendable

    func execute(in state: StoredRuntimeState) throws -> Result
}

public protocol AgentRuntimeQueryableStore: RuntimeStateStoring {
    func execute<Query: AgentQuerySpec>(_ query: Query) async throws -> Query.Result
}

public enum AgentSortOrder: String, Sendable, Hashable, Codable {
    case ascending
    case descending
}

public struct AgentQueryPage: Sendable, Hashable, Codable {
    public var limit: Int
    public var cursor: AgentHistoryCursor?

    public init(
        limit: Int = 50,
        cursor: AgentHistoryCursor? = nil
    ) {
        self.limit = limit
        self.cursor = cursor
    }
}

public enum AgentHistoryItemKind: String, Sendable, Hashable, Codable, CaseIterable {
    case message
    case toolCall
    case toolResult
    case structuredOutput
    case approval
    case systemEvent
}

public struct AgentHistoryQueryResult: Sendable, Hashable {
    public let threadID: String
    public let records: [AgentHistoryRecord]
    public let nextCursor: AgentHistoryCursor?
    public let previousCursor: AgentHistoryCursor?
    public let hasMoreBefore: Bool
    public let hasMoreAfter: Bool

    public init(
        threadID: String,
        records: [AgentHistoryRecord],
        nextCursor: AgentHistoryCursor?,
        previousCursor: AgentHistoryCursor?,
        hasMoreBefore: Bool,
        hasMoreAfter: Bool
    ) {
        self.threadID = threadID
        self.records = records
        self.nextCursor = nextCursor
        self.previousCursor = previousCursor
        self.hasMoreBefore = hasMoreBefore
        self.hasMoreAfter = hasMoreAfter
    }
}

public enum AgentHistorySort: Sendable, Hashable, Codable {
    case sequence(AgentSortOrder)
    case createdAt(AgentSortOrder)
}

public struct HistoryItemsQuery: AgentQuerySpec {
    public typealias Result = AgentHistoryQueryResult

    public var threadID: String
    public var kinds: Set<AgentHistoryItemKind>?
    public var createdAtRange: ClosedRange<Date>?
    public var turnID: String?
    public var includeRedacted: Bool
    public var includeCompactionEvents: Bool
    public var sort: AgentHistorySort
    public var page: AgentQueryPage?

    public init(
        threadID: String,
        kinds: Set<AgentHistoryItemKind>? = nil,
        createdAtRange: ClosedRange<Date>? = nil,
        turnID: String? = nil,
        includeRedacted: Bool = true,
        includeCompactionEvents: Bool = false,
        sort: AgentHistorySort = .sequence(.ascending),
        page: AgentQueryPage? = nil
    ) {
        self.threadID = threadID
        self.kinds = kinds
        self.createdAtRange = createdAtRange
        self.turnID = turnID
        self.includeRedacted = includeRedacted
        self.includeCompactionEvents = includeCompactionEvents
        self.sort = sort
        self.page = page
    }

    public func execute(in state: StoredRuntimeState) throws -> AgentHistoryQueryResult {
        try state.execute(self)
    }
}

public enum AgentThreadMetadataSort: Sendable, Hashable, Codable {
    case updatedAt(AgentSortOrder)
    case createdAt(AgentSortOrder)
}

public struct ThreadMetadataQuery: AgentQuerySpec {
    public typealias Result = [AgentThread]

    public var threadIDs: Set<String>?
    public var statuses: Set<AgentThreadStatus>?
    public var updatedAtRange: ClosedRange<Date>?
    public var sort: AgentThreadMetadataSort
    public var limit: Int?

    public init(
        threadIDs: Set<String>? = nil,
        statuses: Set<AgentThreadStatus>? = nil,
        updatedAtRange: ClosedRange<Date>? = nil,
        sort: AgentThreadMetadataSort = .updatedAt(.descending),
        limit: Int? = nil
    ) {
        self.threadIDs = threadIDs
        self.statuses = statuses
        self.updatedAtRange = updatedAtRange
        self.sort = sort
        self.limit = limit
    }

    public func execute(in state: StoredRuntimeState) throws -> [AgentThread] {
        state.execute(self)
    }
}

public enum AgentPendingStateKind: String, Sendable, Hashable, Codable, CaseIterable {
    case approval
    case userInput
    case toolWait
}

public struct AgentPendingStateRecord: Sendable, Hashable, Codable {
    public let threadID: String
    public let pendingState: AgentThreadPendingState
    public let updatedAt: Date

    public init(
        threadID: String,
        pendingState: AgentThreadPendingState,
        updatedAt: Date
    ) {
        self.threadID = threadID
        self.pendingState = pendingState
        self.updatedAt = updatedAt
    }
}

public enum AgentPendingStateSort: Sendable, Hashable, Codable {
    case updatedAt(AgentSortOrder)
}

public struct PendingStateQuery: AgentQuerySpec {
    public typealias Result = [AgentPendingStateRecord]

    public var threadIDs: Set<String>?
    public var kinds: Set<AgentPendingStateKind>?
    public var sort: AgentPendingStateSort
    public var limit: Int?

    public init(
        threadIDs: Set<String>? = nil,
        kinds: Set<AgentPendingStateKind>? = nil,
        sort: AgentPendingStateSort = .updatedAt(.descending),
        limit: Int? = nil
    ) {
        self.threadIDs = threadIDs
        self.kinds = kinds
        self.sort = sort
        self.limit = limit
    }

    public func execute(in state: StoredRuntimeState) throws -> [AgentPendingStateRecord] {
        state.execute(self)
    }
}

public enum AgentStructuredOutputSort: Sendable, Hashable, Codable {
    case committedAt(AgentSortOrder)
}

public struct StructuredOutputQuery: AgentQuerySpec {
    public typealias Result = [AgentStructuredOutputRecord]

    public var threadIDs: Set<String>?
    public var formatNames: Set<String>?
    public var latestOnly: Bool
    public var sort: AgentStructuredOutputSort
    public var limit: Int?

    public init(
        threadIDs: Set<String>? = nil,
        formatNames: Set<String>? = nil,
        latestOnly: Bool = false,
        sort: AgentStructuredOutputSort = .committedAt(.descending),
        limit: Int? = nil
    ) {
        self.threadIDs = threadIDs
        self.formatNames = formatNames
        self.latestOnly = latestOnly
        self.sort = sort
        self.limit = limit
    }

    public func execute(in state: StoredRuntimeState) throws -> [AgentStructuredOutputRecord] {
        state.execute(self)
    }
}

public struct AgentThreadSnapshot: Sendable, Hashable, Codable {
    public let threadID: String
    public let createdAt: Date
    public let updatedAt: Date
    public let latestItemAt: Date?
    public let itemCount: Int?
    public let latestAssistantMessagePreview: String?
    public let latestStructuredOutputMetadata: AgentStructuredOutputMetadata?
    public let latestPartialStructuredOutput: AgentPartialStructuredOutputSnapshot?
    public let latestToolState: AgentLatestToolState?
    public let latestTurnStatus: AgentTurnStatus?
    public let pendingState: AgentThreadPendingState?

    public init(
        threadID: String,
        createdAt: Date,
        updatedAt: Date,
        latestItemAt: Date? = nil,
        itemCount: Int? = nil,
        latestAssistantMessagePreview: String? = nil,
        latestStructuredOutputMetadata: AgentStructuredOutputMetadata? = nil,
        latestPartialStructuredOutput: AgentPartialStructuredOutputSnapshot? = nil,
        latestToolState: AgentLatestToolState? = nil,
        latestTurnStatus: AgentTurnStatus? = nil,
        pendingState: AgentThreadPendingState? = nil
    ) {
        self.threadID = threadID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.latestItemAt = latestItemAt
        self.itemCount = itemCount
        self.latestAssistantMessagePreview = latestAssistantMessagePreview
        self.latestStructuredOutputMetadata = latestStructuredOutputMetadata
        self.latestPartialStructuredOutput = latestPartialStructuredOutput
        self.latestToolState = latestToolState
        self.latestTurnStatus = latestTurnStatus
        self.pendingState = pendingState
    }
}

public enum AgentThreadSnapshotSort: Sendable, Hashable, Codable {
    case updatedAt(AgentSortOrder)
    case createdAt(AgentSortOrder)
}

public struct ThreadSnapshotQuery: AgentQuerySpec {
    public typealias Result = [AgentThreadSnapshot]

    public var threadIDs: Set<String>?
    public var sort: AgentThreadSnapshotSort
    public var limit: Int?

    public init(
        threadIDs: Set<String>? = nil,
        sort: AgentThreadSnapshotSort = .updatedAt(.descending),
        limit: Int? = nil
    ) {
        self.threadIDs = threadIDs
        self.sort = sort
        self.limit = limit
    }

    public func execute(in state: StoredRuntimeState) throws -> [AgentThreadSnapshot] {
        state.execute(self)
    }
}

public struct AgentRedactionReason: Sendable, Hashable, Codable {
    public let code: String
    public let message: String?

    public init(
        code: String,
        message: String? = nil
    ) {
        self.code = code
        self.message = message
    }
}

public struct AgentHistoryRedaction: Sendable, Hashable, Codable {
    public let redactedAt: Date
    public let reason: AgentRedactionReason?

    public init(
        redactedAt: Date = Date(),
        reason: AgentRedactionReason? = nil
    ) {
        self.redactedAt = redactedAt
        self.reason = reason
    }
}

public struct AgentToolSessionRecord: Sendable, Hashable, Codable {
    public let threadID: String
    public let invocationID: String
    public let turnID: String
    public let toolName: String
    public let sessionID: String?
    public let sessionStatus: String?
    public let metadata: JSONValue?
    public let resumable: Bool
    public let updatedAt: Date

    public init(
        threadID: String,
        invocationID: String,
        turnID: String,
        toolName: String,
        sessionID: String? = nil,
        sessionStatus: String? = nil,
        metadata: JSONValue? = nil,
        resumable: Bool = false,
        updatedAt: Date = Date()
    ) {
        self.threadID = threadID
        self.invocationID = invocationID
        self.turnID = turnID
        self.toolName = toolName
        self.sessionID = sessionID
        self.sessionStatus = sessionStatus
        self.metadata = metadata
        self.resumable = resumable
        self.updatedAt = updatedAt
    }
}

public enum AgentStoreWriteOperation: Sendable, Hashable {
    case upsertThread(AgentThread)
    case upsertSummary(threadID: String, summary: AgentThreadSummary)
    case appendHistoryItems(threadID: String, items: [AgentHistoryRecord])
    case appendCompactionMarker(threadID: String, marker: AgentHistoryRecord)
    case upsertThreadContextState(threadID: String, state: AgentThreadContextState?)
    case deleteThreadContextState(threadID: String)
    case setPendingState(threadID: String, state: AgentThreadPendingState?)
    case setPartialStructuredSnapshot(threadID: String, snapshot: AgentPartialStructuredOutputSnapshot?)
    case upsertToolSession(threadID: String, session: AgentToolSessionRecord)
    case redactHistoryItems(threadID: String, itemIDs: [String], reason: AgentRedactionReason?)
    case deleteThread(threadID: String)
}

public extension AgentRuntimeQueryableStore {
    func execute<Query: AgentQuerySpec>(_ query: Query) async throws -> Query.Result {
        let state = try await loadState()
        return try query.execute(in: state)
    }
}

extension AgentStoreWriteOperation {
    var affectedThreadID: String {
        switch self {
        case let .upsertThread(thread):
            thread.id
        case let .upsertSummary(threadID, _):
            threadID
        case let .appendHistoryItems(threadID, _):
            threadID
        case let .appendCompactionMarker(threadID, _):
            threadID
        case let .upsertThreadContextState(threadID, _):
            threadID
        case let .deleteThreadContextState(threadID):
            threadID
        case let .setPendingState(threadID, _):
            threadID
        case let .setPartialStructuredSnapshot(threadID, _):
            threadID
        case let .upsertToolSession(threadID, _):
            threadID
        case let .redactHistoryItems(threadID, _, _):
            threadID
        case let .deleteThread(threadID):
            threadID
        }
    }
}

extension AgentThreadPendingState {
    var kind: AgentPendingStateKind {
        switch self {
        case .approval:
            .approval
        case .userInput:
            .userInput
        case .toolWait:
            .toolWait
        }
    }
}
