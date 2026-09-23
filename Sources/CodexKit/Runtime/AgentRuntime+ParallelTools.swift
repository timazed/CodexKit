import Foundation

extension AgentRuntime {
    func consumeToolRound(
        _ round: AgentToolRound, turnStream: AgentTurnStream, session: ChatGPTSession,
        policyTracker: TurnSkillPolicyTracker, registrations: [String: ToolRegistry.Entry],
        storesTurnState: Bool, sink: AgentToolEventSink
    ) async throws {
        try Task.checkCancellation()
        let plan = try await policyTracker.plan(round, definitions: registrations.mapValues(\.definition),
            maximumConcurrency: maximumParallelToolCalls)
        let invocationOrder = round.calls.map(\.id)
        // Persist requests before launching tasks; audit results remain chronological.
        if storesTurnState {
            for invocation in round.calls {
                if !(try await hasStoredToolCall(invocationID: invocation.id, in: invocation.threadID)) {
                    try appendHistoryItem(.toolCall(.init(invocation: invocation, requestedAt: Date())),
                        threadID: invocation.threadID, createdAt: Date())
                }
            }
            try await persistState()
        }
        for wave in plan.waves {
            try Task.checkCancellation()
            guard let first = wave.first else { continue }
            let turnID = first.invocation.turnID
            if storesTurnState {
                parallelToolWaits[turnID] = Dictionary(uniqueKeysWithValues: wave.map {
                    ($0.invocation.id, AgentPendingToolWaitState(invocationID: $0.invocation.id,
                        turnID: turnID, toolName: $0.invocation.toolName))
                })
            }
            defer { if storesTurnState { parallelToolWaits[turnID] = nil } }
            try await withThrowingTaskGroup(of: Void.self) { group in
                for admission in wave {
                    group.addTask {
                        try await self.consumeToolInvocation(admission, invocationOrder: invocationOrder,
                            turnStream: turnStream, session: session, policyTracker: policyTracker,
                            registration: registrations[admission.invocation.toolName], storesTurnState: storesTurnState, sink: sink)
                    }
                }
                do {
                    // Observe infrastructure failure promptly; ordinary tool failures
                    // are envelopes and do not cancel sibling calls.
                    for try await _ in group {}
                } catch {
                    group.cancelAll()
                    throw error
                }
            }
        }
    }
}
