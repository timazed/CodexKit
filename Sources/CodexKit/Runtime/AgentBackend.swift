import Foundation

public struct AgentProviderContext: Codable, Hashable, Sendable {
    public let providerID: String
    public let payload: JSONValue

    public init(providerID: String, payload: JSONValue) {
        self.providerID = providerID
        self.payload = payload
    }
}

public enum AgentBackendEvent: Sendable {
    case progress(AgentTurnProgress)
    case rateLimitsUpdated([AgentRateLimitSnapshot])
    case turnStarted(AgentTurn)
    case assistantMessageDelta(threadID: String, turnID: String, delta: String)
    case assistantMessageCompleted(AgentMessage)
    case structuredOutputPartial(JSONValue)
    case structuredOutputCommitted(JSONValue)
    case structuredOutputValidationFailed(AgentStructuredOutputValidationFailure)
    case toolCallRequested(ToolInvocation)
    case toolCallsRequested([ToolInvocation])
    case userMessageAccepted(AgentMessage)
    case providerContextUpdated(threadID: String, context: AgentProviderContext)
    case turnCompleted(AgentTurnSummary)
}

public struct AgentTurnStream: Sendable {
    public let events: AsyncThrowingStream<AgentBackendEvent, Error>
    private let steerHandler: (@Sendable (AgentMessage) async throws -> Void)?
    private let interruptHandler: @Sendable () -> Void
    private let readinessHandler: @Sendable () async throws -> Void
    public var supportsSteering: Bool { steerHandler != nil }
    private let submitToolResultHandler: @Sendable (ToolResultEnvelope, String) async throws -> Void

    public init(
        events: AsyncThrowingStream<AgentBackendEvent, Error>,
        submitToolResult: @escaping @Sendable (ToolResultEnvelope, String) async throws -> Void = { _, _ in }
    ) {
        self.init(events: events, steer: nil, submitToolResult: submitToolResult)
    }

    public init(
        events: AsyncThrowingStream<AgentBackendEvent, Error>,
        steer: (@Sendable (AgentMessage) async throws -> Void)?,
        interrupt: @escaping @Sendable () -> Void = {},
        waitUntilReady: @escaping @Sendable () async throws -> Void = {},
        submitToolResult: @escaping @Sendable (ToolResultEnvelope, String) async throws -> Void = { _, _ in }
    ) {
        self.steerHandler = steer
        self.interruptHandler = interrupt
        self.readinessHandler = waitUntilReady
        self.events = events
        self.submitToolResultHandler = submitToolResult
    }

    public func interrupt() { interruptHandler() }

    /// Waits until the initial request is accepted. Custom backends can supply
    /// a startup handler; the default considers an already-created stream ready.
    public func waitUntilReady() async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await readinessHandler()
            try Task.checkCancellation()
        } onCancel: {
            interruptHandler()
        }
    }

    public func steer(_ message: AgentMessage) async throws {
        guard let steerHandler else {
            throw AgentRuntimeError(code: .steeringUnsupported, message: "This backend does not support steering.")
        }
        try await steerHandler(message)
    }

    public func submitToolResult(_ result: ToolResultEnvelope, for invocationID: String) async throws {
        guard result.invocationID == invocationID else {
            throw AgentRuntimeError(code: .invalidToolResult, message: "The result must identify the requested invocation.")
        }
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

public extension AgentBackend {
    var baseInstructions: String? { get async { nil } }
    var defaultThreadConfiguration: AgentThreadConfiguration? { get async { nil } }
}
