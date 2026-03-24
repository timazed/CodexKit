import Foundation

public struct AgentHistoryRecord: Codable, Hashable, Sendable {
    public let id: String
    public let sequenceNumber: Int
    public let createdAt: Date
    public let item: AgentHistoryItem
    public let redaction: AgentHistoryRedaction?

    public init(
        id: String? = nil,
        sequenceNumber: Int,
        createdAt: Date,
        item: AgentHistoryItem,
        redaction: AgentHistoryRedaction? = nil
    ) {
        self.id = id ?? item.defaultRecordID
        self.sequenceNumber = sequenceNumber
        self.createdAt = createdAt
        self.item = item
        self.redaction = redaction
    }

    enum CodingKeys: String, CodingKey {
        case id
        case sequenceNumber
        case createdAt
        case item
        case redaction
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let sequenceNumber = try container.decode(Int.self, forKey: .sequenceNumber)
        let createdAt = try container.decode(Date.self, forKey: .createdAt)
        let item = try container.decode(AgentHistoryItem.self, forKey: .item)
        let redaction = try container.decodeIfPresent(AgentHistoryRedaction.self, forKey: .redaction)
        self.init(
            id: try container.decodeIfPresent(String.self, forKey: .id),
            sequenceNumber: sequenceNumber,
            createdAt: createdAt,
            item: item,
            redaction: redaction
        )
    }
}

public struct AgentThreadHistoryPage: Sendable, Hashable {
    public let threadID: String
    public let items: [AgentHistoryItem]
    public let nextCursor: AgentHistoryCursor?
    public let previousCursor: AgentHistoryCursor?
    public let hasMoreBefore: Bool
    public let hasMoreAfter: Bool

    public init(
        threadID: String,
        items: [AgentHistoryItem],
        nextCursor: AgentHistoryCursor?,
        previousCursor: AgentHistoryCursor?,
        hasMoreBefore: Bool,
        hasMoreAfter: Bool
    ) {
        self.threadID = threadID
        self.items = items
        self.nextCursor = nextCursor
        self.previousCursor = previousCursor
        self.hasMoreBefore = hasMoreBefore
        self.hasMoreAfter = hasMoreAfter
    }
}

public struct AgentHistoryCursor: Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct AgentHistoryQuery: Sendable, Hashable {
    public var limit: Int
    public var cursor: AgentHistoryCursor?
    public var direction: AgentHistoryDirection
    public var filter: AgentHistoryFilter?

    public init(
        limit: Int = 50,
        cursor: AgentHistoryCursor? = nil,
        direction: AgentHistoryDirection = .backward,
        filter: AgentHistoryFilter? = nil
    ) {
        self.limit = limit
        self.cursor = cursor
        self.direction = direction
        self.filter = filter
    }
}

public enum AgentHistoryDirection: Sendable, Hashable {
    case forward
    case backward
}

public struct AgentHistoryFilter: Sendable, Hashable {
    public var includeMessages: Bool
    public var includeToolCalls: Bool
    public var includeToolResults: Bool
    public var includeStructuredOutputs: Bool
    public var includeApprovals: Bool
    public var includeSystemEvents: Bool
    public var includeCompactionEvents: Bool

    public init(
        includeMessages: Bool = true,
        includeToolCalls: Bool = true,
        includeToolResults: Bool = true,
        includeStructuredOutputs: Bool = true,
        includeApprovals: Bool = true,
        includeSystemEvents: Bool = true,
        includeCompactionEvents: Bool = false
    ) {
        self.includeMessages = includeMessages
        self.includeToolCalls = includeToolCalls
        self.includeToolResults = includeToolResults
        self.includeStructuredOutputs = includeStructuredOutputs
        self.includeApprovals = includeApprovals
        self.includeSystemEvents = includeSystemEvents
        self.includeCompactionEvents = includeCompactionEvents
    }
}

public struct AgentThreadSummary: Codable, Hashable, Sendable {
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

public protocol AgentRuntimeThreadInspecting: Sendable {
    func fetchThreadSummary(id: String) async throws -> AgentThreadSummary
    func fetchThreadHistory(
        id: String,
        query: AgentHistoryQuery
    ) async throws -> AgentThreadHistoryPage
    func fetchLatestStructuredOutputMetadata(id: String) async throws -> AgentStructuredOutputMetadata?
    func fetchThreadContextState(id: String) async throws -> AgentThreadContextState?
}

public extension AgentThreadSummary {
    var snapshot: AgentThreadSnapshot {
        AgentThreadSnapshot(
            threadID: threadID,
            createdAt: createdAt,
            updatedAt: updatedAt,
            latestItemAt: latestItemAt,
            itemCount: itemCount,
            latestAssistantMessagePreview: latestAssistantMessagePreview,
            latestStructuredOutputMetadata: latestStructuredOutputMetadata,
            latestPartialStructuredOutput: latestPartialStructuredOutput,
            latestToolState: latestToolState,
            latestTurnStatus: latestTurnStatus,
            pendingState: pendingState
        )
    }
}
