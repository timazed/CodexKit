import Foundation

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
