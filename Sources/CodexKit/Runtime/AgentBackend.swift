import Foundation

public enum AgentBackendEvent: Sendable {
    case turnStarted(AgentTurn)
    case assistantMessageDelta(threadID: String, turnID: String, delta: String)
    case assistantMessageCompleted(AgentMessage)
    case structuredOutputPartial(JSONValue)
    case structuredOutputCommitted(JSONValue)
    case structuredOutputValidationFailed(AgentStructuredOutputValidationFailure)
    case toolCallRequested(ToolInvocation)
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

public extension AgentBackend {
    var baseInstructions: String? { get async { nil } }
    var defaultThreadConfiguration: AgentThreadConfiguration? { get async { nil } }
}
