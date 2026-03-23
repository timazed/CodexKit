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

    public init(
        includeMessages: Bool = true,
        includeToolCalls: Bool = true,
        includeToolResults: Bool = true,
        includeStructuredOutputs: Bool = true,
        includeApprovals: Bool = true,
        includeSystemEvents: Bool = true
    ) {
        self.includeMessages = includeMessages
        self.includeToolCalls = includeToolCalls
        self.includeToolResults = includeToolResults
        self.includeStructuredOutputs = includeStructuredOutputs
        self.includeApprovals = includeApprovals
        self.includeSystemEvents = includeSystemEvents
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

public enum AgentHistoryItem: Hashable, Sendable {
    case message(AgentMessage)
    case toolCall(AgentToolCallRecord)
    case toolResult(AgentToolResultRecord)
    case structuredOutput(AgentStructuredOutputRecord)
    case approval(AgentApprovalRecord)
    case systemEvent(AgentSystemEventRecord)
}

public struct AgentToolCallRecord: Codable, Hashable, Sendable {
    public let invocation: ToolInvocation
    public let requestedAt: Date

    public init(
        invocation: ToolInvocation,
        requestedAt: Date = Date()
    ) {
        self.invocation = invocation
        self.requestedAt = requestedAt
    }
}

public struct AgentToolResultRecord: Codable, Hashable, Sendable {
    public let threadID: String
    public let turnID: String
    public let result: ToolResultEnvelope
    public let completedAt: Date

    public init(
        threadID: String,
        turnID: String,
        result: ToolResultEnvelope,
        completedAt: Date = Date()
    ) {
        self.threadID = threadID
        self.turnID = turnID
        self.result = result
        self.completedAt = completedAt
    }
}

public struct AgentStructuredOutputRecord: Codable, Hashable, Sendable {
    public let threadID: String
    public let turnID: String
    public let messageID: String?
    public let metadata: AgentStructuredOutputMetadata
    public let committedAt: Date

    public init(
        threadID: String,
        turnID: String,
        messageID: String? = nil,
        metadata: AgentStructuredOutputMetadata,
        committedAt: Date = Date()
    ) {
        self.threadID = threadID
        self.turnID = turnID
        self.messageID = messageID
        self.metadata = metadata
        self.committedAt = committedAt
    }
}

public enum AgentApprovalEventKind: String, Codable, Hashable, Sendable {
    case requested
    case resolved
}

public struct AgentApprovalRecord: Codable, Hashable, Sendable {
    public let kind: AgentApprovalEventKind
    public let request: ApprovalRequest?
    public let resolution: ApprovalResolution?
    public let occurredAt: Date

    public init(
        kind: AgentApprovalEventKind,
        request: ApprovalRequest? = nil,
        resolution: ApprovalResolution? = nil,
        occurredAt: Date = Date()
    ) {
        self.kind = kind
        self.request = request
        self.resolution = resolution
        self.occurredAt = occurredAt
    }
}

public enum AgentSystemEventType: String, Codable, Hashable, Sendable {
    case threadCreated
    case threadResumed
    case threadStatusChanged
    case turnStarted
    case turnCompleted
    case turnFailed
}

public struct AgentSystemEventRecord: Codable, Hashable, Sendable {
    public let type: AgentSystemEventType
    public let threadID: String
    public let turnID: String?
    public let status: AgentThreadStatus?
    public let turnSummary: AgentTurnSummary?
    public let error: AgentRuntimeError?
    public let occurredAt: Date

    public init(
        type: AgentSystemEventType,
        threadID: String,
        turnID: String? = nil,
        status: AgentThreadStatus? = nil,
        turnSummary: AgentTurnSummary? = nil,
        error: AgentRuntimeError? = nil,
        occurredAt: Date = Date()
    ) {
        self.type = type
        self.threadID = threadID
        self.turnID = turnID
        self.status = status
        self.turnSummary = turnSummary
        self.error = error
        self.occurredAt = occurredAt
    }
}

public enum AgentThreadPendingState: Hashable, Sendable {
    case approval(AgentPendingApprovalState)
    case userInput(AgentPendingUserInputState)
    case toolWait(AgentPendingToolWaitState)
}

public struct AgentPendingApprovalState: Codable, Hashable, Sendable {
    public let request: ApprovalRequest
    public let requestedAt: Date

    public init(
        request: ApprovalRequest,
        requestedAt: Date = Date()
    ) {
        self.request = request
        self.requestedAt = requestedAt
    }
}

public struct AgentPendingUserInputState: Codable, Hashable, Sendable {
    public let requestID: String
    public let turnID: String
    public let title: String
    public let message: String
    public let requestedAt: Date

    public init(
        requestID: String,
        turnID: String,
        title: String,
        message: String,
        requestedAt: Date = Date()
    ) {
        self.requestID = requestID
        self.turnID = turnID
        self.title = title
        self.message = message
        self.requestedAt = requestedAt
    }
}

public struct AgentPendingToolWaitState: Codable, Hashable, Sendable {
    public let invocationID: String
    public let turnID: String
    public let toolName: String
    public let startedAt: Date
    public let sessionID: String?
    public let sessionStatus: String?
    public let metadata: JSONValue?
    public let resumable: Bool

    public init(
        invocationID: String,
        turnID: String,
        toolName: String,
        startedAt: Date = Date(),
        sessionID: String? = nil,
        sessionStatus: String? = nil,
        metadata: JSONValue? = nil,
        resumable: Bool = false
    ) {
        self.invocationID = invocationID
        self.turnID = turnID
        self.toolName = toolName
        self.startedAt = startedAt
        self.sessionID = sessionID
        self.sessionStatus = sessionStatus
        self.metadata = metadata
        self.resumable = resumable
    }
}

public enum AgentToolSessionStatus: String, Codable, Hashable, Sendable {
    case waiting
    case running
    case completed
    case failed
    case denied
}

public struct AgentLatestToolState: Codable, Hashable, Sendable {
    public let invocationID: String
    public let turnID: String
    public let toolName: String
    public let status: AgentToolSessionStatus
    public let success: Bool?
    public let sessionID: String?
    public let sessionStatus: String?
    public let metadata: JSONValue?
    public let resumable: Bool
    public let updatedAt: Date
    public let resultPreview: String?

    public init(
        invocationID: String,
        turnID: String,
        toolName: String,
        status: AgentToolSessionStatus,
        success: Bool? = nil,
        sessionID: String? = nil,
        sessionStatus: String? = nil,
        metadata: JSONValue? = nil,
        resumable: Bool = false,
        updatedAt: Date = Date(),
        resultPreview: String? = nil
    ) {
        self.invocationID = invocationID
        self.turnID = turnID
        self.toolName = toolName
        self.status = status
        self.success = success
        self.sessionID = sessionID
        self.sessionStatus = sessionStatus
        self.metadata = metadata
        self.resumable = resumable
        self.updatedAt = updatedAt
        self.resultPreview = resultPreview
    }
}

public struct AgentPartialStructuredOutputSnapshot: Codable, Hashable, Sendable {
    public let turnID: String
    public let formatName: String
    public let payload: JSONValue
    public let updatedAt: Date

    public init(
        turnID: String,
        formatName: String,
        payload: JSONValue,
        updatedAt: Date = Date()
    ) {
        self.turnID = turnID
        self.formatName = formatName
        self.payload = payload
        self.updatedAt = updatedAt
    }
}

extension AgentThreadPendingState: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case approval
        case userInput
        case toolWait
    }

    private enum Kind: String, Codable {
        case approval
        case userInput
        case toolWait
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .approval:
            self = .approval(try container.decode(AgentPendingApprovalState.self, forKey: .approval))
        case .userInput:
            self = .userInput(try container.decode(AgentPendingUserInputState.self, forKey: .userInput))
        case .toolWait:
            self = .toolWait(try container.decode(AgentPendingToolWaitState.self, forKey: .toolWait))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .approval(state):
            try container.encode(Kind.approval, forKey: .kind)
            try container.encode(state, forKey: .approval)
        case let .userInput(state):
            try container.encode(Kind.userInput, forKey: .kind)
            try container.encode(state, forKey: .userInput)
        case let .toolWait(state):
            try container.encode(Kind.toolWait, forKey: .kind)
            try container.encode(state, forKey: .toolWait)
        }
    }
}

extension AgentHistoryItem: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case message
        case toolCall
        case toolResult
        case structuredOutput
        case approval
        case systemEvent
    }

    private enum Kind: String, Codable {
        case message
        case toolCall
        case toolResult
        case structuredOutput
        case approval
        case systemEvent
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .message:
            self = .message(try container.decode(AgentMessage.self, forKey: .message))
        case .toolCall:
            self = .toolCall(try container.decode(AgentToolCallRecord.self, forKey: .toolCall))
        case .toolResult:
            self = .toolResult(try container.decode(AgentToolResultRecord.self, forKey: .toolResult))
        case .structuredOutput:
            self = .structuredOutput(try container.decode(AgentStructuredOutputRecord.self, forKey: .structuredOutput))
        case .approval:
            self = .approval(try container.decode(AgentApprovalRecord.self, forKey: .approval))
        case .systemEvent:
            self = .systemEvent(try container.decode(AgentSystemEventRecord.self, forKey: .systemEvent))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .message(message):
            try container.encode(Kind.message, forKey: .kind)
            try container.encode(message, forKey: .message)
        case let .toolCall(record):
            try container.encode(Kind.toolCall, forKey: .kind)
            try container.encode(record, forKey: .toolCall)
        case let .toolResult(record):
            try container.encode(Kind.toolResult, forKey: .kind)
            try container.encode(record, forKey: .toolResult)
        case let .structuredOutput(record):
            try container.encode(Kind.structuredOutput, forKey: .kind)
            try container.encode(record, forKey: .structuredOutput)
        case let .approval(record):
            try container.encode(Kind.approval, forKey: .kind)
            try container.encode(record, forKey: .approval)
        case let .systemEvent(record):
            try container.encode(Kind.systemEvent, forKey: .kind)
            try container.encode(record, forKey: .systemEvent)
        }
    }
}

extension AgentHistoryFilter {
    func matches(_ item: AgentHistoryItem) -> Bool {
        switch item {
        case .message:
            includeMessages
        case .toolCall:
            includeToolCalls
        case .toolResult:
            includeToolResults
        case .structuredOutput:
            includeStructuredOutputs
        case .approval:
            includeApprovals
        case .systemEvent:
            includeSystemEvents
        }
    }
}

extension AgentHistoryItem {
    var kind: AgentHistoryItemKind {
        switch self {
        case .message:
            .message
        case .toolCall:
            .toolCall
        case .toolResult:
            .toolResult
        case .structuredOutput:
            .structuredOutput
        case .approval:
            .approval
        case .systemEvent:
            .systemEvent
        }
    }

    var turnID: String? {
        switch self {
        case let .message(message):
            return message.structuredOutput == nil ? nil : nil
        case let .toolCall(record):
            return record.invocation.turnID
        case let .toolResult(record):
            return record.turnID
        case let .structuredOutput(record):
            return record.turnID
        case let .approval(record):
            return record.request?.turnID ?? record.resolution?.turnID
        case let .systemEvent(record):
            return record.turnID
        }
    }

    var defaultRecordID: String {
        switch self {
        case let .message(message):
            return "message:\(message.id)"
        case let .toolCall(record):
            return "toolCall:\(record.invocation.id)"
        case let .toolResult(record):
            return "toolResult:\(record.result.invocationID)"
        case let .structuredOutput(record):
            return "structuredOutput:\(record.messageID ?? record.turnID)"
        case let .approval(record):
            return "approval:\(record.request?.id ?? record.resolution?.requestID ?? UUID().uuidString)"
        case let .systemEvent(record):
            return "systemEvent:\(record.type.rawValue):\(record.turnID ?? record.threadID)"
        }
    }
}

extension AgentHistoryRecord {
    func redacted(reason: AgentRedactionReason?) -> AgentHistoryRecord {
        AgentHistoryRecord(
            id: id,
            sequenceNumber: sequenceNumber,
            createdAt: createdAt,
            item: item.redactedPayload(),
            redaction: AgentHistoryRedaction(reason: reason)
        )
    }
}

private extension AgentHistoryItem {
    func redactedPayload() -> AgentHistoryItem {
        switch self {
        case let .message(message):
            return .message(
                AgentMessage(
                    id: message.id,
                    threadID: message.threadID,
                    role: message.role,
                    text: "[Redacted]",
                    images: [],
                    structuredOutput: message.structuredOutput.map {
                        AgentStructuredOutputMetadata(
                            formatName: $0.formatName,
                            payload: .object(["redacted": .bool(true)])
                        )
                    },
                    createdAt: message.createdAt
                )
            )

        case let .toolCall(record):
            return .toolCall(
                AgentToolCallRecord(
                    invocation: ToolInvocation(
                        id: record.invocation.id,
                        threadID: record.invocation.threadID,
                        turnID: record.invocation.turnID,
                        toolName: record.invocation.toolName,
                        arguments: .object(["redacted": .bool(true)])
                    ),
                    requestedAt: record.requestedAt
                )
            )

        case let .toolResult(record):
            return .toolResult(
                AgentToolResultRecord(
                    threadID: record.threadID,
                    turnID: record.turnID,
                    result: ToolResultEnvelope(
                        invocationID: record.result.invocationID,
                        toolName: record.result.toolName,
                        success: record.result.success,
                        content: [.text("[Redacted]")],
                        errorMessage: record.result.errorMessage == nil ? nil : "[Redacted]",
                        session: record.result.session
                    ),
                    completedAt: record.completedAt
                )
            )

        case let .structuredOutput(record):
            return .structuredOutput(
                AgentStructuredOutputRecord(
                    threadID: record.threadID,
                    turnID: record.turnID,
                    messageID: record.messageID,
                    metadata: AgentStructuredOutputMetadata(
                        formatName: record.metadata.formatName,
                        payload: .object(["redacted": .bool(true)])
                    ),
                    committedAt: record.committedAt
                )
            )

        case let .approval(record):
            let request = record.request.map {
                ApprovalRequest(
                    id: $0.id,
                    threadID: $0.threadID,
                    turnID: $0.turnID,
                    toolInvocation: ToolInvocation(
                        id: $0.toolInvocation.id,
                        threadID: $0.toolInvocation.threadID,
                        turnID: $0.toolInvocation.turnID,
                        toolName: $0.toolInvocation.toolName,
                        arguments: .object(["redacted": .bool(true)])
                    ),
                    title: "[Redacted]",
                    message: "[Redacted]"
                )
            }
            return .approval(
                AgentApprovalRecord(
                    kind: record.kind,
                    request: request,
                    resolution: record.resolution,
                    occurredAt: record.occurredAt
                )
            )

        case let .systemEvent(record):
            return .systemEvent(
                AgentSystemEventRecord(
                    type: record.type,
                    threadID: record.threadID,
                    turnID: record.turnID,
                    status: record.status,
                    turnSummary: record.turnSummary,
                    error: record.error.map {
                        AgentRuntimeError(code: $0.code, message: "[Redacted]")
                    },
                    occurredAt: record.occurredAt
                )
            )
        }
    }
}
