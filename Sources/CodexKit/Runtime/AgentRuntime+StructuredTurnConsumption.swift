import Foundation

extension AgentRuntime {
    func consumeStructuredTurnStream<Output: Decodable & Sendable>(
        _ turnStream: AgentTurnStream,
        for threadID: String,
        userMessage: AgentMessage?,
        session: ChatGPTSession,
        resolvedTurnSkills: ResolvedTurnSkills,
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
        var assistantMessages: [AgentMessage] = []
        var sawStructuredCommit = false
        var currentTurnID: String?
        var didCompleteTurn = false

        do {
            for try await backendEvent in turnStream.events {
                switch backendEvent {
                case let .turnStarted(turn):
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

                case let .assistantMessageDelta(threadID, turnID, delta):
                    continuation.yield(
                        .assistantMessageDelta(
                            threadID: threadID,
                            turnID: turnID,
                            delta: delta
                        )
                    )

                case let .assistantMessageCompleted(message):
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
                    if storesTurnState {
                        try? setLatestPartialStructuredOutput(nil, for: threadID)
                        try? await persistState()
                    }
                    continuation.yield(.structuredOutputValidationFailed(validationFailure))

                case let .toolCallRequested(invocation):
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
                    continuation.yield(.toolCallStarted(invocation))

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
                            continuation: continuation
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
                    continuation.yield(.toolCallFinished(result))
                    if storesTurnState {
                        try await setThreadStatus(.streaming, for: threadID)
                        continuation.yield(.threadStatusChanged(threadID: threadID, status: .streaming))
                    }

                case let .providerContextUpdated(eventThreadID, context):
                    guard storesTurnState, eventThreadID == threadID else {
                        break
                    }
                    updateProviderContext(context, for: threadID)
                    try await persistState()

                case let .turnRecoveryCheckpointUpdated(checkpoint):
                    guard storesTurnState, checkpoint.turnID == currentTurnID else { break }
                    try await persistRecoveryCheckpoint(checkpoint, for: threadID)

                case let .turnCompleted(summary):
                    didCompleteTurn = true
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

                    if storesTurnState {
                        try appendHistoryItem(
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
                        if let userMessage {
                            await automaticallyCaptureMemoriesIfConfigured(
                                for: threadID,
                                userMessage: userMessage,
                                assistantMessages: assistantMessages
                            )
                        }
                        continuation.yield(.threadStatusChanged(threadID: threadID, status: .idle))
                    }
                    continuation.yield(.turnCompleted(summary))
                }
            }

            if !didCompleteTurn {
                try Task.checkCancellation()
            }
            continuation.finish()
        } catch {
            if storesTurnState,
               shouldPreserveTurnForRecovery(
                   error: error,
                   threadID: threadID,
                   turnID: currentTurnID
               ) {
                continuation.finish(throwing: error)
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
