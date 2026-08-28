import Foundation

public struct AgentProviderContext: Codable, Hashable, Sendable {
    public let providerID: String
    public let payload: JSONValue

    public init(providerID: String, payload: JSONValue) {
        self.providerID = providerID
        self.payload = payload
    }
}

/// An opaque provider checkpoint for a model response that can continue without
/// resubmitting the original turn.
public struct AgentTurnRecoveryCheckpoint: Codable, Hashable, Sendable {
    public let providerID: String
    public let threadID: String
    public let turnID: String
    public let request: Request
    public let payload: JSONValue
    public let providerAttachments: [AgentImageAttachment]
    public let createdAt: Date

    public init(
        providerID: String,
        threadID: String,
        turnID: String,
        request: Request,
        payload: JSONValue,
        providerAttachments: [AgentImageAttachment] = [],
        createdAt: Date = Date()
    ) {
        self.providerID = providerID
        self.threadID = threadID
        self.turnID = turnID
        self.request = request
        self.payload = payload
        self.providerAttachments = providerAttachments
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case providerID
        case threadID
        case turnID
        case request
        case payload
        case providerAttachments
        case createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providerID = try container.decode(String.self, forKey: .providerID)
        threadID = try container.decode(String.self, forKey: .threadID)
        turnID = try container.decode(String.self, forKey: .turnID)
        request = try container.decode(Request.self, forKey: .request)
        payload = try container.decode(JSONValue.self, forKey: .payload)
        providerAttachments = try container.decodeIfPresent(
            [AgentImageAttachment].self,
            forKey: .providerAttachments
        ) ?? []
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }
}

public enum AgentBackendEvent: Sendable {
    case turnStarted(AgentTurn)
    case assistantMessageDelta(threadID: String, turnID: String, delta: String)
    case assistantMessageCompleted(AgentMessage)
    case structuredOutputPartial(JSONValue)
    case structuredOutputCommitted(JSONValue)
    case structuredOutputValidationFailed(AgentStructuredOutputValidationFailure)
    case toolCallRequested(ToolInvocation)
    case turnRecoveryCheckpointUpdated(AgentTurnRecoveryCheckpoint)
    case providerContextUpdated(threadID: String, context: AgentProviderContext)
    case turnCompleted(AgentTurnSummary)
}

public struct AgentTurnStream: Sendable {
    public let events: AsyncThrowingStream<AgentBackendEvent, Error>
    private let submitToolResultHandler: @Sendable (ToolResultEnvelope, String) async throws -> Void

    public init(
        events: AsyncThrowingStream<AgentBackendEvent, Error>,
        submitToolResult: @escaping @Sendable (ToolResultEnvelope, String) async throws -> Void = { _, _ in }
    ) {
        self.events = events
        self.submitToolResultHandler = submitToolResult
    }

    public func submitToolResult(_ result: ToolResultEnvelope, for invocationID: String) async throws {
        try await submitToolResultHandler(result, invocationID)
    }
}

public protocol AgentBackend: Sendable {
    var baseInstructions: String? { get async }
    var defaultThreadConfiguration: AgentThreadConfiguration? { get async }
    func createThread(session: ChatGPTSession) async throws -> AgentThread
    func resumeThread(id: String, session: ChatGPTSession) async throws -> AgentThread
    func beginTurn(
        thread: AgentThread,
        history: [AgentMessage],
        message: Request,
        instructions: String,
        responseFormat: AgentStructuredOutputFormat?,
        streamedStructuredOutput: AgentStreamedStructuredOutputRequest?,
        tools: [ToolDefinition],
        session: ChatGPTSession
    ) async throws -> AgentTurnStream
}

public protocol AgentBackendProviderContextSupporting: AgentBackend {
    func beginTurn(
        thread: AgentThread,
        history: [AgentMessage],
        providerContext: AgentProviderContext?,
        message: Request,
        instructions: String,
        responseFormat: AgentStructuredOutputFormat?,
        streamedStructuredOutput: AgentStreamedStructuredOutputRequest?,
        tools: [ToolDefinition],
        session: ChatGPTSession
    ) async throws -> AgentTurnStream
}

/// A backend that can reattach to an already-created provider response.
public protocol AgentBackendTurnRecoverySupporting: AgentBackend {
    func resumeTurn(
        from checkpoint: AgentTurnRecoveryCheckpoint,
        history: [AgentMessage],
        tools: [ToolDefinition],
        session: ChatGPTSession
    ) async throws -> AgentTurnStream
}

public extension AgentBackend {
    var baseInstructions: String? { get async { nil } }
    var defaultThreadConfiguration: AgentThreadConfiguration? { get async { nil } }
}
