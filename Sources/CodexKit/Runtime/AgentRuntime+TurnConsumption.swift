import Foundation

extension AgentRuntime {
    // MARK: - Turn Consumption

    func consumeTurnStream(
        _ turnStream: AgentTurnStream,
        for threadID: String,
        userMessage: AgentMessage?,
        session: ChatGPTSession,
        resolvedTurnSkills: ResolvedTurnSkills,
        resolvedInstructions: ResolvedAgentInstructions,
        clientRequestID: String? = nil,
        storesTurnState: Bool = true,
        completionCapture: AgentTurnCompletionCapture? = nil,
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    ) async {
        let policyTracker: TurnSkillPolicyTracker? = if resolvedTurnSkills.compiledToolPolicy.hasConstraints {
            TurnSkillPolicyTracker(policy: resolvedTurnSkills.compiledToolPolicy)
        } else {
            nil
        }
        let toolSink = AgentToolEventSink { continuation.yield($0) }
        var assistantMessages: [AgentMessage] = []
        var currentTurnID: String?
        var currentTurnStartedAt: Date?

        defer { turnStream.interrupt() }
        do {
            for try await backendEvent in turnStream.events {
                switch backendEvent {
                case let .progress(progress):
                    try validateBackendTurnEvent(threadID: progress.threadID, turnID: progress.turnID,
                        expectedThreadID: threadID, currentTurnID: currentTurnID)
                    continuation.yield(.progress(progress))

                case let .rateLimitsUpdated(snapshots):
                    continuation.yield(.rateLimitsUpdated(snapshots))

                case let .turnStarted(turn):
                    try validateTurnStart(
                        turn,
                        expectedThreadID: threadID,
                        currentTurnID: currentTurnID
                    )
                    logger.info(
                        .runtime,
                        "Turn started.",
                        metadata: [
                            "thread_id": threadID,
                            "turn_id": turn.id
                        ]
                    )
                    if storesTurnState { activeTurnExecutions[threadID]?.turnID = turn.id }
                    currentTurnID = turn.id
                    currentTurnStartedAt = turn.startedAt
                    if storesTurnState,
                       !hasStoredTurnStart(turnID: turn.id, in: threadID) {
                        try appendHistoryItem(
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
                    }
                    continuation.yield(.turnStarted(turn))

                case let .assistantMessageDelta(eventThreadID, eventTurnID, delta):
                    try validateBackendTurnEvent(
                        threadID: eventThreadID,
                        turnID: eventTurnID,
                        expectedThreadID: threadID,
                        currentTurnID: currentTurnID
                    )
                    continuation.yield(
                        .assistantMessageDelta(
                            threadID: eventThreadID,
                            turnID: eventTurnID,
                            delta: delta
                        )
                    )

                case let .assistantMessageCompleted(message):
                    try validateAssistantMessageEvent(
                        message,
                        expectedThreadID: threadID,
                        currentTurnID: currentTurnID
                    )
                    let isDuplicate = storesTurnState && hasCommittedMessage(
                        id: message.id,
                        in: threadID
                    )
                    if storesTurnState, !isDuplicate {
                        try await appendMessage(message)
                        if message.role == .assistant {
                            assistantMessages.append(message)
                        }
                    }
                    logger.debug(
                        .runtime,
                        "Assistant message committed.",
                        metadata: [
                            "thread_id": threadID,
                            "turn_id": currentTurnID ?? "",
                            "text_length": "\(message.text.count)",
                            "image_count": "\(message.images.count)"
                        ]
                    )
                    if !isDuplicate {
                        continuation.yield(.messageCommitted(message))
                    }

                case .structuredOutputPartial,
                     .structuredOutputCommitted,
                     .structuredOutputValidationFailed:
                    try validateActiveTurn(
                        expectedThreadID: threadID,
                        currentTurnID: currentTurnID
                    )
                    break

                case let .toolCallRequested(invocation):
                    try validateBackendTurnEvent(threadID: invocation.threadID, turnID: invocation.turnID,
                        expectedThreadID: threadID, currentTurnID: currentTurnID)
                    try await consumeToolInvocations([invocation], turnStream: turnStream, session: session,
                        policyTracker: policyTracker, storesTurnState: storesTurnState, sink: toolSink)

                case let .toolCallsRequested(invocations):
                    for invocation in invocations {
                        try validateBackendTurnEvent(threadID: invocation.threadID, turnID: invocation.turnID,
                            expectedThreadID: threadID, currentTurnID: currentTurnID)
                    }
                    try await consumeToolInvocations(invocations, turnStream: turnStream, session: session,
                        policyTracker: policyTracker, storesTurnState: storesTurnState, sink: toolSink)

                case let .userMessageAccepted(message):
                    try validateActiveTurn(expectedThreadID: threadID, currentTurnID: currentTurnID)
                    guard message.threadID == threadID, message.role == .user else {
                        throw AgentRuntimeError.invalidMessageContent()
                    }
                    if storesTurnState { try await appendMessage(message) }
                    continuation.yield(.messageCommitted(message))

                case let .providerContextUpdated(eventThreadID, context):
                    try validateProviderContextEvent(
                        threadID: eventThreadID,
                        expectedThreadID: threadID,
                        currentTurnID: currentTurnID
                    )
                    guard storesTurnState else { break }
                    updateProviderContext(context, for: threadID)
                    try await persistState()

                case let .turnCompleted(summary):
                    try Task.checkCancellation()
                    if storesTurnState { activeTurnExecutions[threadID]?.isFinishing = true }
                    try validateTurnCompletion(
                        summary,
                        expectedThreadID: threadID,
                        currentTurnID: currentTurnID
                    )
                    if let completionError = policyTracker?.completionError() {
                        if storesTurnState {
                            try appendHistoryItem(
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
                        }
                        continuation.yield(.turnFailed(completionError))
                        continuation.finish(throwing: completionError)
                        return
                    }

                    let memoryApplicationOutcome = makeMemoryApplicationOutcome(
                        resolvedInstructions: resolvedInstructions,
                        threadID: threadID,
                        turnID: summary.turnID,
                        clientRequestID: clientRequestID,
                        resolvedTurnSkills: resolvedTurnSkills
                    )
                    let memoryApplication = memoryApplicationOutcome.snapshot

                    if storesTurnState {
                        try appendHistoryItem(
                            .systemEvent(
                                AgentSystemEventRecord(
                                    type: .turnCompleted,
                                    threadID: threadID,
                                    turnID: summary.turnID,
                                    turnSummary: summary,
                                    memoryApplication: memoryApplication,
                                    occurredAt: summary.completedAt
                                )
                            ),
                            threadID: threadID,
                            createdAt: summary.completedAt
                        )
                        try setLatestTurnStatus(.completed, for: threadID)
                        try setLatestPartialStructuredOutput(nil, for: threadID)
                        try await setThreadStatus(.idle, for: threadID)
                        if let userMessage {
                            await automaticallyCaptureMemoriesIfConfigured(
                                for: threadID,
                                userMessage: userMessage,
                                assistantMessages: assistantMessages
                            )
                        }
                    }
                    logger.info(
                        .runtime,
                        "Turn completed.",
                        metadata: [
                            "thread_id": threadID,
                            "turn_id": summary.turnID,
                            "assistant_messages": "\(assistantMessages.count)",
                            "input_tokens": "\(summary.usage?.inputTokens ?? 0)",
                            "cached_input_tokens": "\(summary.usage?.cachedInputTokens ?? 0)",
                            "output_tokens": "\(summary.usage?.outputTokens ?? 0)"
                            ,
                            "duration_ms": "\(currentTurnStartedAt.map { Int(summary.completedAt.timeIntervalSince($0) * 1000) } ?? 0)"
                        ]
                    )
                    if storesTurnState {
                        continuation.yield(.threadStatusChanged(threadID: threadID, status: .idle))
                    }
                    await completionCapture?.record(
                        memoryApplication: memoryApplicationOutcome
                    )
                    notifyMemoryApplication(memoryApplication)
                    continuation.yield(.turnCompleted(summary))
                    continuation.finish()
                    return
                }
            }

            try Task.checkCancellation()
            continuation.finish()
        } catch {
            if error is CancellationError || Task.isCancelled {
                let interruption = await recordInterruption(in: threadID, turnID: currentTurnID, storesTurnState: storesTurnState)
                if storesTurnState { continuation.yield(.threadStatusChanged(threadID: threadID, status: .idle)) }
                continuation.yield(.turnInterrupted(interruption))
                continuation.finish(throwing: CancellationError())
                return
            }
            let runtimeError = (error as? AgentRuntimeError)
                ?? AgentRuntimeError(
                    code: "turn_failed",
                    message: error.localizedDescription
                )
            if storesTurnState {
                _ = try? appendHistoryItem(
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
            }
            logger.error(
                .runtime,
                "Turn failed.",
                metadata: [
                    "thread_id": threadID,
                    "turn_id": currentTurnID ?? "",
                    "error": runtimeError.message,
                    "duration_ms": "\(currentTurnStartedAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? 0)"
                ]
            )
            if storesTurnState {
                continuation.yield(.threadStatusChanged(threadID: threadID, status: .failed))
            }
            continuation.yield(.turnFailed(runtimeError))
            continuation.finish(throwing: error)
        }
    }
}
