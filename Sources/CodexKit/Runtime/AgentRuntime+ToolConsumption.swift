import Foundation

struct AgentToolEventSink: Sendable {
    let yield: @Sendable (AgentEvent) async throws -> Void
}

extension AgentRuntime {
    func consumeToolInvocation(
        _ invocation: ToolInvocation,
        turnStream: AgentTurnStream,
        session: ChatGPTSession,
        policyTracker: TurnSkillPolicyTracker?,
        registration: ToolRegistry.Entry?,
        storesTurnState: Bool,
        sink: AgentToolEventSink
    ) async throws {
        try Task.checkCancellation()
        let threadID = invocation.threadID
        let existingToolResult = storesTurnState
            ? try await storedToolResult(invocationID: invocation.id, in: invocation.threadID)
            : nil
        if storesTurnState,
           !(try await hasStoredToolCall(invocationID: invocation.id, in: invocation.threadID)) {
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
        try await sink.yield(.toolCallStarted(invocation))

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
                registration: registration,
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
        try await sink.yield(.toolCallFinished(result))
        if storesTurnState {
            parallelToolWaits[invocation.turnID]?[invocation.id] = nil
        }
        if storesTurnState, parallelToolWaits[invocation.turnID]?.isEmpty != false {
            try await setThreadStatus(.streaming, for: threadID)
            try await sink.yield(.threadStatusChanged(threadID: threadID, status: .streaming))
        }
    }
}
