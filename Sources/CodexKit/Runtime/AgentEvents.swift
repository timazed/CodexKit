public enum AgentEvent: Sendable {
    case threadStarted(AgentThread)
    case threadStatusChanged(threadID: String, status: AgentThreadStatus)
    case progress(AgentTurnProgress)
    case rateLimitsUpdated([AgentRateLimitSnapshot])
    case turnStarted(AgentTurn)
    case assistantMessageDelta(threadID: String, turnID: String, delta: String)
    case messageCommitted(AgentMessage)
    case approvalRequested(ApprovalRequest)
    case approvalResolved(ApprovalResolution)
    case toolCallStarted(ToolInvocation)
    case toolCallFinished(ToolResultEnvelope)
    case turnCompleted(AgentTurnSummary)
    case turnInterrupted(AgentTurnInterruption)
    case turnFailed(AgentRuntimeError)
}

/// A successfully decoded or collected response together with the runtime turn
/// that produced it.
public struct AgentTurnResult<Value: Sendable>: Sendable {
    public let value: Value
    public let summary: AgentTurnSummary
    public let clientRequestID: String?
    public let memoryApplication: MemoryApplicationOutcome

    public init(
        value: Value,
        summary: AgentTurnSummary,
        clientRequestID: String? = nil,
        memoryApplication: MemoryApplicationOutcome = .notApplied(.notReported)
    ) {
        self.value = value
        self.summary = summary
        self.clientRequestID = clientRequestID
        self.memoryApplication = memoryApplication
    }

    /// The exact memory applied to this turn, when memory was applied.
    public var memoryApplicationSnapshot: MemoryApplicationSnapshot? {
        memoryApplication.snapshot
    }
}
