import Foundation

public struct AgentStructuredStreamingOptions: Sendable, Hashable {
    public var required: Bool
    public var emitPartials: Bool

    public init(
        required: Bool = false,
        emitPartials: Bool = true
    ) {
        self.required = required
        self.emitPartials = emitPartials
    }
}

public struct AgentStructuredOutputMetadata: Codable, Hashable, Sendable {
    public let formatName: String
    public let payload: JSONValue

    public init(
        formatName: String,
        payload: JSONValue
    ) {
        self.formatName = formatName
        self.payload = payload
    }
}

public enum AgentStructuredOutputValidationStage: String, Codable, Hashable, Sendable {
    case partial
    case committed
}

public struct AgentStructuredOutputValidationFailure: Error, Hashable, Sendable {
    public let stage: AgentStructuredOutputValidationStage
    public let message: String
    public let rawPayload: String?

    public init(
        stage: AgentStructuredOutputValidationStage,
        message: String,
        rawPayload: String? = nil
    ) {
        self.stage = stage
        self.message = message
        self.rawPayload = rawPayload
    }
}

public enum AgentStructuredStreamEvent<Output: Sendable>: Sendable {
    case threadStarted(AgentThread)
    case threadStatusChanged(threadID: String, status: AgentThreadStatus)
    case turnStarted(AgentTurn)
    case assistantMessageDelta(threadID: String, turnID: String, delta: String)
    case messageCommitted(AgentMessage)
    case approvalRequested(ApprovalRequest)
    case approvalResolved(ApprovalResolution)
    case toolCallStarted(ToolInvocation)
    case toolCallFinished(ToolResultEnvelope)
    case structuredOutputPartial(Output)
    case structuredOutputCommitted(Output)
    case structuredOutputValidationFailed(AgentStructuredOutputValidationFailure)
    case turnCompleted(AgentTurnSummary)
    case turnFailed(AgentRuntimeError)
}

public struct AgentStreamedStructuredOutputRequest: Sendable, Hashable {
    public let responseFormat: AgentStructuredOutputFormat
    public let options: AgentStructuredStreamingOptions

    public init(
        responseFormat: AgentStructuredOutputFormat,
        options: AgentStructuredStreamingOptions
    ) {
        self.responseFormat = responseFormat
        self.options = options
    }
}
