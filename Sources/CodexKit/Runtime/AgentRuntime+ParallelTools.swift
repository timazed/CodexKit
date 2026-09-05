import Foundation

extension AgentRuntime {
    func consumeToolInvocations(
        _ invocations: [ToolInvocation], turnStream: AgentTurnStream, session: ChatGPTSession,
        policyTracker: TurnSkillPolicyTracker?, storesTurnState: Bool, sink: AgentToolEventSink
    ) async throws {
        guard Set(invocations.map(\.id)).count == invocations.count else {
            throw AgentRuntimeError(code: "duplicate_tool_call", message: "A tool batch contains duplicate call IDs.")
        }
        var parallel: [ToolInvocation] = []
        for invocation in invocations {
            try Task.checkCancellation()
            let definition = await toolRegistry.definition(named: invocation.toolName)
            // Skill sequences and call limits retain their existing serial semantics.
            let canOverlap = policyTracker == nil && definition?.supportsParallelExecution == true
                && definition?.approvalPolicy == .automatic
            if canOverlap {
                parallel.append(invocation)
                if parallel.count == maximumParallelToolCalls {
                    try await consumeParallelBatch(parallel, turnStream: turnStream, session: session,
                                                   storesTurnState: storesTurnState, sink: sink)
                    parallel.removeAll()
                }
            } else {
                try await consumeParallelBatch(parallel, turnStream: turnStream, session: session,
                                               storesTurnState: storesTurnState, sink: sink)
                parallel.removeAll()
                try await consumeToolInvocation(invocation, turnStream: turnStream, session: session,
                    policyTracker: policyTracker, storesTurnState: storesTurnState, sink: sink)
            }
        }
        try await consumeParallelBatch(parallel, turnStream: turnStream, session: session,
                                       storesTurnState: storesTurnState, sink: sink)
    }

    private func consumeParallelBatch(
        _ invocations: [ToolInvocation], turnStream: AgentTurnStream, session: ChatGPTSession,
        storesTurnState: Bool, sink: AgentToolEventSink
    ) async throws {
        guard let first = invocations.first else { return }
        if storesTurnState {
            parallelToolWaits[first.turnID] = Dictionary(uniqueKeysWithValues: invocations.map {
                ($0.id, AgentPendingToolWaitState(invocationID: $0.id, turnID: $0.turnID,
                    toolName: $0.toolName))
            })
        }
        defer { if storesTurnState { parallelToolWaits[first.turnID] = nil } }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for invocation in invocations {
                group.addTask {
                    try await self.consumeToolInvocation(invocation, turnStream: turnStream, session: session,
                        policyTracker: nil, storesTurnState: storesTurnState, sink: sink)
                }
            }
            try await group.waitForAll()
        }
    }
}
