import Foundation

extension CodexResponsesTurnRunner {
    func resolvePendingFunctionCalls(state: inout TurnRunState) async throws {
        guard !state.pendingFunctionCalls.isEmpty else { return }
        let invocations = state.pendingFunctionCalls.map {
            ToolInvocation(id: $0.callID, threadID: threadID, turnID: turnID,
                           toolName: $0.name, arguments: $0.arguments)
        }
        guard Set(invocations.map(\.id)).count == invocations.count else {
            throw AgentRuntimeError(code: "duplicate_tool_call", message: "Response contains duplicate tool call IDs.")
        }
        continuation.yield(.toolCallsRequested(invocations))
        // Results may arrive out of order; provider history always uses call order.
        for invocation in invocations {
            try Task.checkCancellation()
            try await collectToolResult(invocation, state: &state)
        }
        state.pendingFunctionCalls.removeAll()
    }
}
