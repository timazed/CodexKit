import Foundation

public struct AgentRuntimeError: Error, LocalizedError, Equatable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? {
        message
    }

    public static func signedOut() -> AgentRuntimeError {
        AgentRuntimeError(code: "signed_out", message: "No ChatGPT session is available.")
    }

    public static func threadNotFound(_ threadID: String) -> AgentRuntimeError {
        AgentRuntimeError(
            code: "thread_not_found",
            message: "The assistant thread \(threadID) could not be found."
        )
    }

    public static func unauthorized(_ message: String = "The ChatGPT session is no longer authorized.") -> AgentRuntimeError {
        AgentRuntimeError(code: "unauthorized", message: message)
    }
}

public enum AgentRole: String, Codable, Hashable, Sendable {
    case user
    case assistant
    case tool
    case system
}

public enum AgentThreadStatus: String, Codable, Hashable, Sendable {
    case idle
    case streaming
    case waitingForApproval
    case waitingForToolResult
    case failed
}

public enum AgentTurnStatus: String, Codable, Hashable, Sendable {
    case running
    case completed
    case failed
}

public struct AgentUsage: Codable, Hashable, Sendable {
    public var inputTokens: Int
    public var cachedInputTokens: Int
    public var outputTokens: Int

    public init(inputTokens: Int = 0, cachedInputTokens: Int = 0, outputTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
    }
}

public struct UserMessageRequest: Codable, Hashable, Sendable {
    public var text: String

    public init(text: String) {
        self.text = text
    }
}

public struct AgentThread: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var title: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var status: AgentThreadStatus

    public init(
        id: String,
        title: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        status: AgentThreadStatus = .idle
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.status = status
    }
}

public struct AgentTurn: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var threadID: String
    public var status: AgentTurnStatus
    public var startedAt: Date

    public init(
        id: String,
        threadID: String,
        status: AgentTurnStatus = .running,
        startedAt: Date = Date()
    ) {
        self.id = id
        self.threadID = threadID
        self.status = status
        self.startedAt = startedAt
    }
}

public struct AgentMessage: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var threadID: String
    public var role: AgentRole
    public var text: String
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        threadID: String,
        role: AgentRole,
        text: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.threadID = threadID
        self.role = role
        self.text = text
        self.createdAt = createdAt
    }
}

public struct AgentTurnSummary: Codable, Hashable, Sendable {
    public var threadID: String
    public var turnID: String
    public var usage: AgentUsage?
    public var completedAt: Date

    public init(
        threadID: String,
        turnID: String,
        usage: AgentUsage? = nil,
        completedAt: Date = Date()
    ) {
        self.threadID = threadID
        self.turnID = turnID
        self.usage = usage
        self.completedAt = completedAt
    }
}

public enum AgentEvent: Sendable {
    case threadStarted(AgentThread)
    case threadStatusChanged(threadID: String, status: AgentThreadStatus)
    case turnStarted(AgentTurn)
    case assistantMessageDelta(threadID: String, turnID: String, delta: String)
    case messageCommitted(AgentMessage)
    case approvalRequested(ApprovalRequest)
    case approvalResolved(ApprovalResolution)
    case toolCallStarted(ToolInvocation)
    case toolCallFinished(ToolResultEnvelope)
    case turnCompleted(AgentTurnSummary)
    case turnFailed(AgentRuntimeError)
}
