import Foundation

extension AgentRuntime {
    // MARK: - Turn Consumption

    func consumeTurnStream<Output: Decodable & Sendable>(
        _ turnStream: AgentTurnStream,
        for threadID: String,
        userMessage: AgentMessage?,
        session: ChatGPTSession,
        budget: AgentTurnBudget,
        control: AgentExecutionControl,
        registrations: [String: ToolRegistry.Entry],
        resolvedTurnSkills: ResolvedTurnSkills,
        resolvedInstructions: ResolvedAgentInstructions,
        clientRequestID: String? = nil,
        storesTurnState: Bool = true,
        completionCapture: AgentTurnCompletionCapture? = nil,
        structured: AgentStructuredTurnConfiguration<Output>? = nil,
        oneShotValidation: AgentOneShotResponseValidation? = nil,
        continuation: AgentTurnEventSink<Output>
    ) async {
        let policyTracker: TurnSkillPolicyTracker? = if resolvedTurnSkills.compiledToolPolicy.hasConstraints {
            TurnSkillPolicyTracker(policy: resolvedTurnSkills.compiledToolPolicy)
        } else {
            nil
        }
        let toolSink = AgentToolEventSink { try await continuation.yield($0) }
        var assistantMessages: [AgentMessage] = []
        var sawStructuredCommit = false
        var sawOneShotResponse = false
        var currentTurnID: String?
        var currentTurnStartedAt: Date?

        do {
            for try await backendEvent in turnStream.events {
                try await validateActiveAuthentication(session)
                switch backendEvent {
                case let .progress(progress):
                    try validateBackendTurnEvent(threadID: progress.threadID, turnID: progress.turnID,
                        expectedThreadID: threadID, currentTurnID: currentTurnID)
                    try await continuation.yield(.progress(progress))

                case let .rateLimitsUpdated(snapshots):
                    try await continuation.yield(.rateLimitsUpdated(snapshots))

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
                       !(try await hasStoredTurnStart(turnID: turn.id, in: threadID)) {
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
                    try await continuation.yield(.turnStarted(turn))

                case let .assistantMessageDelta(eventThreadID, eventTurnID, delta):
                    try validateBackendTurnEvent(
                        threadID: eventThreadID,
                        turnID: eventTurnID,
                        expectedThreadID: threadID,
                        currentTurnID: currentTurnID
                    )
                    try await continuation.yield(
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
                    if let oneShotValidation, message.phase != .commentary {
                        try await oneShotValidation.validate(message)
                        sawOneShotResponse = true
                    }
                    let isDuplicate = storesTurnState ? try await hasCommittedMessage(
                        id: message.id,
                        in: threadID
                    ) : false
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
                        try await continuation.yield(.messageCommitted(message))
                    }

                case .structuredOutputPartial, .structuredOutputCommitted, .structuredOutputValidationFailed:
                    try validateActiveTurn(expectedThreadID: threadID, currentTurnID: currentTurnID)
                    if let structured, let currentTurnID {
                        let committed = try await consumeStructuredOutput(backendEvent, in: threadID, turnID: currentTurnID,
                            configuration: structured, storesTurnState: storesTurnState, sink: continuation)
                        sawStructuredCommit = sawStructuredCommit || committed
                    }

                case let .toolCallRequested(invocation):
                    try budget.claimToolCalls(1)
                    try validateBackendTurnEvent(threadID: invocation.threadID, turnID: invocation.turnID,
                        expectedThreadID: threadID, currentTurnID: currentTurnID)
                    try await consumeToolInvocations([invocation], turnStream: turnStream, session: session,
                        policyTracker: policyTracker, registrations: registrations, storesTurnState: storesTurnState, sink: toolSink)

                case let .toolCallsRequested(invocations):
                    try budget.claimToolCalls(invocations.count)
                    for invocation in invocations {
                        try validateBackendTurnEvent(threadID: invocation.threadID, turnID: invocation.turnID,
                            expectedThreadID: threadID, currentTurnID: currentTurnID)
                    }
                    try await consumeToolInvocations(invocations, turnStream: turnStream, session: session,
                        policyTracker: policyTracker, registrations: registrations, storesTurnState: storesTurnState, sink: toolSink)

                case let .userMessageAccepted(message):
                    try validateActiveTurn(expectedThreadID: threadID, currentTurnID: currentTurnID)
                    guard message.threadID == threadID, message.role == .user else {
                        throw AgentRuntimeError.invalidMessageContent()
                    }
                    if storesTurnState { try await appendMessage(message) }
                    try await continuation.yield(.messageCommitted(message))

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
                    if let completionError = policyTracker?.completionError() { throw completionError }
                    if let structured, structured.options.required, !sawStructuredCommit {
                        throw AgentRuntimeError.structuredOutputMissing(formatName: structured.format.name)
                    }
                    if let oneShotValidation, !sawOneShotResponse {
                        throw AgentRuntimeError.structuredOutputMissing(formatName: oneShotValidation.format.name)
                    }
                    try budget.acceptCompletion()

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
                    await completionCapture?.record(
                        memoryApplication: memoryApplicationOutcome
                    )
                    notifyMemoryApplication(memoryApplication)
                    let terminalEvents: [AgentEvent] = (storesTurnState ? [.threadStatusChanged(threadID: threadID, status: .idle)] : [])
                        + [.turnCompleted(summary)]
                    control.finish()
                    budget.finish()
                    if let id = budget.executionID { releaseTurn(in: threadID, executionID: id) }
                    continuation.finish(events: terminalEvents)
                    return
                }
            }

            try Task.checkCancellation()
            throw AgentRuntimeError.turnSummaryMissing()
        } catch {
            await finishFailedTurn(error, in: threadID, turnID: currentTurnID, storesTurnState: storesTurnState, budget: budget, control: control, sink: continuation)
        }
    }
}
