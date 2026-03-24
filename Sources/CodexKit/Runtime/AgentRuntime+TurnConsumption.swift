import Foundation

extension AgentRuntime {
    // MARK: - Turn Consumption

    func consumeTurnStream(
        _ turnStream: any AgentTurnStreaming,
        for threadID: String,
        userMessage: AgentMessage,
        session: ChatGPTSession,
        resolvedTurnSkills: ResolvedTurnSkills,
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    ) async {
        let policyTracker: TurnSkillPolicyTracker? = if resolvedTurnSkills.compiledToolPolicy.hasConstraints {
            TurnSkillPolicyTracker(policy: resolvedTurnSkills.compiledToolPolicy)
        } else {
            nil
        }
        var assistantMessages: [AgentMessage] = []
        var currentTurnID: String?

        do {
            for try await backendEvent in turnStream.events {
                switch backendEvent {
                case let .turnStarted(turn):
                    currentTurnID = turn.id
                    appendHistoryItem(
                        .systemEvent(
                            AgentSystemEventRecord(
                                type: .turnStarted,
                                threadID: threadID,
                                turnID: turn.id,
                                occurredAt: turn.startedAt
                            )
                        ),
                        threadID: threadID,
                        createdAt: turn.startedAt
                    )
                    try setLatestTurnStatus(.running, for: threadID)
                    updateThreadTimestamp(turn.startedAt, for: threadID)
                    try await persistState()
                    continuation.yield(.turnStarted(turn))

                case let .assistantMessageDelta(threadID, turnID, delta):
                    continuation.yield(
                        .assistantMessageDelta(
                            threadID: threadID,
                            turnID: turnID,
                            delta: delta
                        )
                    )

                case let .assistantMessageCompleted(message):
                    try await appendMessage(message)
                    if message.role == .assistant {
                        assistantMessages.append(message)
                    }
                    continuation.yield(.messageCommitted(message))

                case .structuredOutputPartial,
                     .structuredOutputCommitted,
                     .structuredOutputValidationFailed:
                    break

                case let .toolCallRequested(invocation):
                    appendHistoryItem(
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
                    continuation.yield(.toolCallStarted(invocation))

                    let result: ToolResultEnvelope
                    if let policyTracker,
                       let validationError = policyTracker.validate(toolName: invocation.toolName) {
                        result = .failure(
                            invocation: invocation,
                            message: validationError.message
                        )
                    } else {
                        let resolvedResult = try await resolveToolInvocation(
                            invocation,
                            session: session,
                            continuation: continuation
                        )
                        result = resolvedResult
                        policyTracker?.recordAccepted(toolName: invocation.toolName)
                    }

                    try await turnStream.submitToolResult(result, for: invocation.id)
                    continuation.yield(.toolCallFinished(result))
                    try await setThreadStatus(.streaming, for: threadID)
                    continuation.yield(.threadStatusChanged(threadID: threadID, status: .streaming))

                case let .turnCompleted(summary):
                    if let completionError = policyTracker?.completionError() {
                        appendHistoryItem(
                            .systemEvent(
                                AgentSystemEventRecord(
                                    type: .turnFailed,
                                    threadID: threadID,
                                    turnID: currentTurnID,
                                    error: completionError,
                                    occurredAt: Date()
                                )
                            ),
                            threadID: threadID,
                            createdAt: Date()
                        )
                        try setLatestTurnStatus(.failed, for: threadID)
                        try setLatestPartialStructuredOutput(nil, for: threadID)
                        try await setThreadStatus(.failed, for: threadID)
                        continuation.yield(.threadStatusChanged(threadID: threadID, status: .failed))
                        continuation.yield(.turnFailed(completionError))
                        continuation.finish(throwing: completionError)
                        return
                    }

                    appendHistoryItem(
                        .systemEvent(
                            AgentSystemEventRecord(
                                type: .turnCompleted,
                                threadID: threadID,
                                turnID: summary.turnID,
                                turnSummary: summary,
                                occurredAt: summary.completedAt
                            )
                        ),
                        threadID: threadID,
                        createdAt: summary.completedAt
                    )
                    try setLatestTurnStatus(.completed, for: threadID)
                    try setLatestPartialStructuredOutput(nil, for: threadID)
                    try await setThreadStatus(.idle, for: threadID)
                    await automaticallyCaptureMemoriesIfConfigured(
                        for: threadID,
                        userMessage: userMessage,
                        assistantMessages: assistantMessages
                    )
                    continuation.yield(.threadStatusChanged(threadID: threadID, status: .idle))
                    continuation.yield(.turnCompleted(summary))
                }
            }

            continuation.finish()
        } catch {
            let runtimeError = (error as? AgentRuntimeError)
                ?? AgentRuntimeError(
                    code: "turn_failed",
                    message: error.localizedDescription
                )
            appendHistoryItem(
                .systemEvent(
                    AgentSystemEventRecord(
                        type: .turnFailed,
                        threadID: threadID,
                        turnID: currentTurnID,
                        error: runtimeError,
                        occurredAt: Date()
                    )
                ),
                threadID: threadID,
                createdAt: Date()
            )
            try? setLatestTurnStatus(.failed, for: threadID)
            try? setLatestPartialStructuredOutput(nil, for: threadID)
            try? await setThreadStatus(.failed, for: threadID)
            continuation.yield(.threadStatusChanged(threadID: threadID, status: .failed))
            continuation.yield(.turnFailed(runtimeError))
            continuation.finish(throwing: error)
        }
    }
}
