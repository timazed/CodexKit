import Foundation

public enum AgentBackendEvent: Sendable {
    case turnStarted(AgentTurn)
    case assistantMessageDelta(threadID: String, turnID: String, delta: String)
    case assistantMessageCompleted(AgentMessage)
    case toolCallRequested(ToolInvocation)
    case turnCompleted(AgentTurnSummary)
}

public protocol AgentTurnStreaming: Sendable {
    var events: AsyncThrowingStream<AgentBackendEvent, Error> { get }
    func submitToolResult(_ result: ToolResultEnvelope, for invocationID: String) async throws
}

public protocol AgentBackend: Sendable {
    func createThread(session: ChatGPTSession) async throws -> AgentThread
    func resumeThread(id: String, session: ChatGPTSession) async throws -> AgentThread
    func beginTurn(
        thread: AgentThread,
        history: [AgentMessage],
        message: UserMessageRequest,
        tools: [ToolDefinition],
        session: ChatGPTSession
    ) async throws -> any AgentTurnStreaming
}
