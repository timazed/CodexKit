import Foundation

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
    case turnInterrupted
    case contextCompacted
}

public struct AgentSystemEventRecord: Codable, Hashable, Sendable {
    public let type: AgentSystemEventType
    public let threadID: String
    public let turnID: String?
    public let status: AgentThreadStatus?
    public let turnSummary: AgentTurnSummary?
    public let error: AgentRuntimeError?
    public let compaction: AgentContextCompactionMarker?
    /// Durable attribution for memory used by a completed threaded turn.
    public let memoryApplication: MemoryApplicationSnapshot?
    /// Durable attribution for memory used by a successful compaction.
    public let memoryCompactionApplication: MemoryCompactionApplicationSnapshot?
    public let occurredAt: Date

    public init(
        type: AgentSystemEventType,
        threadID: String,
        turnID: String? = nil,
        status: AgentThreadStatus? = nil,
        turnSummary: AgentTurnSummary? = nil,
        error: AgentRuntimeError? = nil,
        compaction: AgentContextCompactionMarker? = nil,
        memoryApplication: MemoryApplicationSnapshot?,
        memoryCompactionApplication: MemoryCompactionApplicationSnapshot? = nil,
        occurredAt: Date = Date()
    ) {
        self.type = type
        self.threadID = threadID
        self.turnID = turnID
        self.status = status
        self.turnSummary = turnSummary
        self.error = error
        self.compaction = compaction
        self.memoryApplication = memoryApplication
        self.memoryCompactionApplication = memoryCompactionApplication
        self.occurredAt = occurredAt
    }

    /// Preserves the original source-compatible initializer and defaults.
    public init(
        type: AgentSystemEventType,
        threadID: String,
        turnID: String? = nil,
        status: AgentThreadStatus? = nil,
        turnSummary: AgentTurnSummary? = nil,
        error: AgentRuntimeError? = nil,
        compaction: AgentContextCompactionMarker? = nil,
        occurredAt: Date = Date()
    ) {
        self.init(
            type: type,
            threadID: threadID,
            turnID: turnID,
            status: status,
            turnSummary: turnSummary,
            error: error,
            compaction: compaction,
            memoryApplication: nil,
            memoryCompactionApplication: nil,
            occurredAt: occurredAt
        )
    }
}
