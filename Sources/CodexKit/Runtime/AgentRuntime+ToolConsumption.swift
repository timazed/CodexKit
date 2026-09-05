import Foundation

struct AgentToolEventSink: Sendable {
    let yield: @Sendable (AgentEvent) -> Void
}

extension AgentRuntime {
    func consumeToolInvocation(
        _ invocation: ToolInvocation,
        turnStream: AgentTurnStream,
        session: ChatGPTSession,
        policyTracker: TurnSkillPolicyTracker?,
        storesTurnState: Bool,
        sink: AgentToolEventSink
    ) async throws {
        try Task.checkCancellation()
        let threadID = invocation.threadID
        let existingToolResult = storesTurnState
            ? storedToolResult(invocationID: invocation.id, in: invocation.threadID)
            : nil
        if storesTurnState,
           !hasStoredToolCall(invocationID: invocation.id, in: invocation.threadID) {
            try appendHistoryItem(
                .toolCall(
                    AgentToolCallRecord(
                        invocation: invocation,
                        requestedAt: Date()
                    )
                ),
                threadID: invocation.threadID,
                createdAt: Date()
            )
            try setLatestToolState(
                latestToolState(for: invocation, result: nil, updatedAt: Date()),
                for: invocation.threadID
            )
            updateThreadTimestamp(Date(), for: invocation.threadID)
            try await persistState()
        }
        sink.yield(.toolCallStarted(invocation))

        let result: ToolResultEnvelope
        if let existingToolResult {
            result = existingToolResult
            policyTracker?.recordAccepted(toolName: invocation.toolName)
        } else if let policyTracker,
           let validationError = policyTracker.validate(toolName: invocation.toolName) {
            result = .failure(
                invocation: invocation,
                message: validationError.message
            )
        } else {
            let resolvedResult = try await resolveToolInvocation(
                invocation,
                session: session,
                storesTurnState: storesTurnState,
                sink: sink
            )
            result = resolvedResult
            policyTracker?.recordAccepted(toolName: invocation.toolName)
        }

        if storesTurnState,
           existingToolResult == nil,
           result.session?.isTerminal != false {
            appendEffectiveToolInteraction(
                invocation: invocation,
                result: result
            )
            try await persistState()
        }
        try await turnStream.submitToolResult(result, for: invocation.id)
        sink.yield(.toolCallFinished(result))
        if storesTurnState {
            parallelToolWaits[invocation.turnID]?[invocation.id] = nil
        }
        if storesTurnState, parallelToolWaits[invocation.turnID]?.isEmpty != false {
            try await setThreadStatus(.streaming, for: threadID)
            sink.yield(.threadStatusChanged(threadID: threadID, status: .streaming))
        }
    }
}
