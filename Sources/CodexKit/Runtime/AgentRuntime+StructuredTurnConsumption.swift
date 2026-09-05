import Foundation

extension AgentRuntime {
    func consumeStructuredTurnStream<Output: Decodable & Sendable>(
        _ turnStream: AgentTurnStream,
        for threadID: String,
        userMessage: AgentMessage?,
        session: ChatGPTSession,
        resolvedTurnSkills: ResolvedTurnSkills,
        resolvedInstructions: ResolvedAgentInstructions,
        clientRequestID: String? = nil,
        responseFormat: AgentStructuredOutputFormat,
        options: AgentStructuredStreamingOptions,
        decoder: JSONDecoder,
        outputType: Output.Type,
        storesTurnState: Bool = true,
        continuation: AsyncThrowingStream<AgentStructuredStreamEvent<Output>, Error>.Continuation
    ) async {
        let policyTracker: TurnSkillPolicyTracker? = if resolvedTurnSkills.compiledToolPolicy.hasConstraints {
            TurnSkillPolicyTracker(policy: resolvedTurnSkills.compiledToolPolicy)
        } else {
            nil
        }
        let toolSink = AgentToolEventSink { event in
            switch event {
            case let .toolCallStarted(value): continuation.yield(.toolCallStarted(value))
            case let .toolCallFinished(value): continuation.yield(.toolCallFinished(value))
            case let .approvalRequested(value): continuation.yield(.approvalRequested(value))
            case let .approvalResolved(value): continuation.yield(.approvalResolved(value))
            case let .threadStatusChanged(id, status): continuation.yield(.threadStatusChanged(threadID: id, status: status))
            default: break
            }
        }
        var assistantMessages: [AgentMessage] = []
        var sawStructuredCommit = false
        var currentTurnID: String?

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
                    if storesTurnState { activeTurnExecutions[threadID]?.turnID = turn.id }
                    currentTurnID = turn.id
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
                    if !isDuplicate {
                        continuation.yield(.messageCommitted(message))
                    }

                case let .structuredOutputPartial(value):
                    try validateActiveTurn(
                        expectedThreadID: threadID,
                        currentTurnID: currentTurnID
                    )
                    do {
                        let decoded = try decodeStructuredValue(
                            value,
                            as: outputType,
                            decoder: decoder
                        )
                        if storesTurnState, let currentTurnID {
                            try setLatestPartialStructuredOutput(
                                AgentPartialStructuredOutputSnapshot(
                                    turnID: currentTurnID,
                                    formatName: responseFormat.name,
                                    payload: value,
                                    updatedAt: Date()
                                ),
                                for: threadID
                            )
                            updateThreadTimestamp(Date(), for: threadID)
                            try await persistState()
                        }
                        if options.emitPartials {
                            continuation.yield(.structuredOutputPartial(decoded))
                        }
                    } catch {
                        continuation.yield(
                            .structuredOutputValidationFailed(
                                AgentStructuredOutputValidationFailure(
                                    stage: .partial,
                                    message: error.localizedDescription,
                                    rawPayload: value.prettyJSONString
                                )
                            )
                        )
                    }

                case let .structuredOutputCommitted(value):
                    try validateActiveTurn(
                        expectedThreadID: threadID,
                        currentTurnID: currentTurnID
                    )
                    do {
                        let decoded = try decodeStructuredValue(
                            value,
                            as: outputType,
                            decoder: decoder
                        )
                        sawStructuredCommit = true
                        let metadata = AgentStructuredOutputMetadata(
                            formatName: responseFormat.name,
                            payload: value
                        )
                        let isDuplicate = storesTurnState && currentTurnID.map {
                            hasStoredStructuredOutput(
                                turnID: $0,
                                formatName: responseFormat.name,
                                in: threadID
                            )
                        } == true
                        if storesTurnState, !isDuplicate {
                            try setLatestStructuredOutputMetadata(metadata, for: threadID)
                            try setLatestPartialStructuredOutput(nil, for: threadID)
                            try appendHistoryItem(
                                .structuredOutput(
                                    AgentStructuredOutputRecord(
                                        threadID: threadID,
                                        turnID: currentTurnID ?? "",
                                        metadata: metadata,
                                        committedAt: Date()
                                    )
                                ),
                                threadID: threadID,
                                createdAt: Date()
                            )
                            updateThreadTimestamp(Date(), for: threadID)
                            try await persistState()
                        }
                        if !isDuplicate {
                            continuation.yield(.structuredOutputCommitted(decoded))
                        }
                    } catch {
                        let validationFailure = AgentStructuredOutputValidationFailure(
                            stage: .committed,
                            message: error.localizedDescription,
                            rawPayload: value.prettyJSONString
                        )
                        let runtimeError = AgentRuntimeError.structuredOutputInvalid(
                            stage: validationFailure.stage,
                            underlyingMessage: validationFailure.message
                        )
                        if storesTurnState {
                            try? setLatestPartialStructuredOutput(nil, for: threadID)
                            try appendHistoryItem(
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
                            try await setThreadStatus(.failed, for: threadID)
                            continuation.yield(.threadStatusChanged(threadID: threadID, status: .failed))
                        }
                        continuation.yield(.structuredOutputValidationFailed(validationFailure))
                        continuation.yield(.turnFailed(runtimeError))
                        continuation.finish(throwing: runtimeError)
                        return
                    }

                case let .structuredOutputValidationFailed(validationFailure):
                    try validateActiveTurn(
                        expectedThreadID: threadID,
                        currentTurnID: currentTurnID
                    )
                    if storesTurnState {
                        try? setLatestPartialStructuredOutput(nil, for: threadID)
                        try? await persistState()
                    }
                    continuation.yield(.structuredOutputValidationFailed(validationFailure))

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

                    if options.required, !sawStructuredCommit {
                        let runtimeError = AgentRuntimeError.structuredOutputMissing(
                            formatName: responseFormat.name
                        )
                        if storesTurnState {
                            try appendHistoryItem(
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
                            try setLatestTurnStatus(.failed, for: threadID)
                            try setLatestPartialStructuredOutput(nil, for: threadID)
                            try await setThreadStatus(.failed, for: threadID)
                            continuation.yield(.threadStatusChanged(threadID: threadID, status: .failed))
                        }
                        continuation.yield(.turnFailed(runtimeError))
                        continuation.finish(throwing: runtimeError)
                        return
                    }

                    let memoryApplication = makeMemoryApplicationSnapshot(
                        resolvedInstructions: resolvedInstructions,
                        threadID: threadID,
                        turnID: summary.turnID,
                        clientRequestID: clientRequestID,
                        resolvedTurnSkills: resolvedTurnSkills
                    )

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
                        continuation.yield(.threadStatusChanged(threadID: threadID, status: .idle))
                    }
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
                continuation.yield(.threadStatusChanged(threadID: threadID, status: .failed))
            }
            continuation.yield(.turnFailed(runtimeError))
            continuation.finish(throwing: error)
        }
    }
}
