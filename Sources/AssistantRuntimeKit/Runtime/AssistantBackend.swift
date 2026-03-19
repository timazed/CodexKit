import Foundation

public enum BackendTurnEvent: Sendable {
    case turnStarted(AssistantTurn)
    case assistantMessageDelta(threadID: String, turnID: String, delta: String)
    case assistantMessageCompleted(AssistantMessage)
    case toolCallRequested(ToolInvocation)
    case turnCompleted(AssistantTurnSummary)
}

public protocol AssistantTurnStreaming: Sendable {
    var events: AsyncThrowingStream<BackendTurnEvent, Error> { get }
    func submitToolResult(_ result: ToolResultEnvelope, for invocationID: String) async throws
}

public protocol AssistantBackend: Sendable {
    func createThread(session: ChatGPTSession) async throws -> AssistantThread
    func resumeThread(id: String, session: ChatGPTSession) async throws -> AssistantThread
    func beginTurn(
        thread: AssistantThread,
        message: UserMessageRequest,
        tools: [ToolDefinition],
        session: ChatGPTSession
    ) async throws -> any AssistantTurnStreaming
}
