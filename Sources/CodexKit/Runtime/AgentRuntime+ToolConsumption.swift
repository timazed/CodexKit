import Foundation

struct AgentToolEventSink: Sendable {
    let yield: @Sendable (AgentEvent) async throws -> Void
}

extension AgentRuntime {
    func consumeToolInvocation(
        _ admission: ToolAdmission,
        invocationOrder: [String],
        turnStream: AgentTurnStream,
        session: ChatGPTSession,
        policyTracker: TurnSkillPolicyTracker,
        registration: ToolRegistry.Entry?,
        storesTurnState: Bool,
        sink: AgentToolEventSink
    ) async throws {
        try Task.checkCancellation()
        try await validateActiveAuthentication(session)
        let invocation = admission.invocation
        let existing = storesTurnState
            ? try await storedToolResult(invocationID: invocation.id, in: invocation.threadID) : nil
        try await sink.yield(.toolCallStarted(invocation))
        let result: ToolResultEnvelope
        if let existing {
            // A persisted invocation is an immutable outcome, not a new side effect.
            result = existing
        } else if let failure = admission.failure {
            result = .failure(invocation: invocation, message: failure.message, code: failure.code)
        } else {
            result = try await resolveToolInvocation(invocation, session: session, registration: registration,
                storesTurnState: storesTurnState, sink: sink)
        }
        try Task.checkCancellation()
        try await validateActiveAuthentication(session)
        await policyTracker.recordSettled(admission)
        try await finalizeToolInvocation(invocation, result: result, invocationOrder: invocationOrder,
            alreadyStored: existing != nil, storesTurnState: storesTurnState)
        try Task.checkCancellation()
        try await turnStream.submitToolResult(result, for: invocation.id)
        try await sink.yield(.toolCallFinished(result))
        if storesTurnState, parallelToolWaits[invocation.turnID]?.isEmpty != false,
           result.session?.isTerminal != false {
            try await setThreadStatus(.streaming, for: invocation.threadID)
            try await sink.yield(.threadStatusChanged(threadID: invocation.threadID, status: .streaming))
        }
    }

    /// Settled results share the audit, pending-state and context path.
    /// Cancellation keeps the interrupted-turn path and submits no result.
    private func finalizeToolInvocation(
        _ invocation: ToolInvocation, result: ToolResultEnvelope, invocationOrder: [String],
        alreadyStored: Bool, storesTurnState: Bool
    ) async throws {
        guard storesTurnState else { return }
        let now = Date()
        try setLatestToolState(latestToolState(for: invocation, result: result, updatedAt: now), for: invocation.threadID)
        if let session = result.session, !session.isTerminal {
            let wait = AgentPendingToolWaitState(invocationID: invocation.id, turnID: invocation.turnID,
                toolName: invocation.toolName, startedAt: now, sessionID: session.sessionID,
                sessionStatus: session.status, metadata: session.metadata, resumable: session.resumable)
            parallelToolWaits[invocation.turnID]?[invocation.id] = wait
            try setPendingState(.toolWait(wait), for: invocation.threadID)
        } else {
            parallelToolWaits[invocation.turnID]?[invocation.id] = nil
            let remaining = parallelToolWaits[invocation.turnID]?.values.sorted { $0.invocationID < $1.invocationID }.first
            try setPendingState(remaining.map(AgentThreadPendingState.toolWait), for: invocation.threadID)
            if !alreadyStored {
                try appendHistoryItem(.toolResult(.init(threadID: invocation.threadID, turnID: invocation.turnID,
                    result: result, completedAt: now)), threadID: invocation.threadID, createdAt: now)
                appendEffectiveToolInteraction(invocation: invocation, result: result, completedAt: now,
                    invocationOrder: invocationOrder)
            }
        }
        updateThreadTimestamp(now, for: invocation.threadID)
        try await persistState()
    }
}
