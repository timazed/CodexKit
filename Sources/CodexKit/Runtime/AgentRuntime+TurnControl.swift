import Foundation

public struct AgentTurnInterruption: Sendable {
    public let threadID: String
    public let turnID: String?
    public let interruptedAt: Date

    public init(threadID: String, turnID: String?, interruptedAt: Date = Date()) {
        self.threadID = threadID
        self.turnID = turnID
        self.interruptedAt = interruptedAt
    }
}

struct AgentActiveTurnExecution {
    let id: UUID
    let cancellation = AgentTurnCancellationHandle()
    var isFinishing = false
    var turnID: String?
    var stream: AgentTurnStream?
}

extension AgentRuntime {
    public func activeTurnID(in threadID: String) -> String? {
        guard activeTurnExecutions[threadID]?.isFinishing == false else { return nil }
        return activeTurnExecutions[threadID]?.turnID
    }

    /// Adds input at the next model-request boundary without starting another turn.
    /// The accepted message is committed when the backend consumes it.
    public func steer(_ text: String, images: [AgentImageAttachment] = [], in threadID: String,
                      expectedTurnID: String) async throws {
        guard let execution = activeTurnExecutions[threadID], !execution.isFinishing, execution.turnID == expectedTurnID,
              let stream = execution.stream else { throw inactiveTurnError() }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty else {
            throw AgentRuntimeError.invalidMessageContent()
        }
        try await stream.steer(.init(threadID: threadID, role: .user, text: text, images: images))
    }

    /// Requests cooperative cancellation, including while waiting for a tool or approval.
    public func interrupt(in threadID: String, expectedTurnID: String? = nil) throws {
        guard let execution = activeTurnExecutions[threadID], !execution.isFinishing,
              expectedTurnID == nil || execution.turnID == expectedTurnID else { throw inactiveTurnError() }
        activeTurnExecutions[threadID]?.isFinishing = true
        execution.stream?.interrupt()
        execution.cancellation.cancel()
    }

    func reserveTurn(in threadID: String) throws -> AgentActiveTurnExecution {
        let execution = AgentActiveTurnExecution(id: try reserveThreadOperation(in: threadID))
        activeTurnExecutions[threadID] = execution
        return execution
    }

    func releaseTurn(in threadID: String, executionID: UUID) {
        guard activeTurnExecutions[threadID]?.id == executionID else { return }
        activeTurnExecutions[threadID] = nil
        releaseThreadOperation(in: threadID, id: executionID)
    }

    func recordInterruption(in threadID: String, turnID: String?, storesTurnState: Bool,
        waitForPersistence: Bool = true) async -> AgentTurnInterruption {
        if storesTurnState { activeTurnExecutions[threadID]?.isFinishing = true }
        let interruption = AgentTurnInterruption(threadID: threadID, turnID: turnID)
        if storesTurnState {
            _ = try? appendHistoryItem(.systemEvent(.init(type: .turnInterrupted, threadID: threadID,
                turnID: turnID, occurredAt: interruption.interruptedAt)), threadID: threadID,
                createdAt: interruption.interruptedAt)
            try? setLatestTurnStatus(.interrupted, for: threadID)
            try? setPendingState(nil, for: threadID)
            try? setLatestPartialStructuredOutput(nil, for: threadID)
            try? await setThreadStatus(.idle, for: threadID, waitDespiteCancellation: waitForPersistence)
        }
        return interruption
    }

    private func inactiveTurnError() -> AgentRuntimeError {
        .init(code: .turnNotActive, message: "The expected turn is no longer active.")
    }
}
