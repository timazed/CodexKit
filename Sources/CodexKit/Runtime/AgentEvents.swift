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

/// A successfully decoded or collected response together with the runtime turn
/// that produced it.
public struct AgentTurnResult<Value: Sendable>: Sendable {
    public let value: Value
    public let summary: AgentTurnSummary

    public init(value: Value, summary: AgentTurnSummary) {
        self.value = value
        self.summary = summary
    }
}
