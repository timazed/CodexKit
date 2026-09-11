import Foundation

extension CodexResponsesTurnRunner {
    func handleStreamEvent(
        _ event: CodexResponsesStreamEvent,
        state: inout TurnRunState
    ) async throws -> StreamEventResult {
        switch event.kind {
        case let .progress(progress):
            try await continuation.yield(.progress(.init(threadID: threadID, turnID: turnID, content: progress)))
            return .assistantDelta

        case let .rateLimits(snapshots):
            await streamClient.rateLimitObserver(snapshots)
            try await continuation.yield(.rateLimitsUpdated(snapshots))
            return .none

        case .responseCreated:
            return .none
        case let .failed(error, _):
            throw error

        case let .assistantTextDelta(delta):
            let emittedDelta = try await handleAssistantTextDelta(delta, state: &state)
            return emittedDelta ? .assistantDelta : .none

        case let .outputItem(item, outputIndex):
            try streamClient.responseBudget?.consumeItem()
            state.pendingResponseItems.append(
                PendingResponseItem(
                    outputIndex: outputIndex,
                    sequenceNumber: event.sequenceNumber,
                    arrivalOrder: state.pendingResponseItems.count,
                    value: item.rawValue
                )
            )
            if let progress = item.completedProgress {
                try await continuation.yield(.progress(.init(threadID: threadID, turnID: turnID, content: progress)))
            }
            switch item.kind {
            case let .message(messageItem):
                let text = messageItem.content
                    .compactMap(\.displayText)
                    .joined()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let images = messageItem.content.compactMap(\.imageAttachment)
                guard !text.isEmpty || !images.isEmpty else {
                    return .none
                }
                try await handleAssistantMessage(
                    AgentMessage(
                        id: messageItem.id ?? UUID().uuidString,
                        threadID: "",
                        role: .assistant,
                        text: text,
                        images: images,
                        phase: messageItem.phase
                    ),
                    state: &state
                )
                return .assistantMessage

            case let .functionCall(functionCallItem):
                state.hasToolActivity = true
                guard AgentStructuredRecoveryContext.current == nil else {
                    throw AgentRecoveryError.toolsUnsupported
                }
                let functionCall = FunctionCallRecord(
                    name: functionCallItem.name,
                    callID: functionCallItem.callID,
                    argumentsRaw: functionCallItem.arguments
                )
                if let previous = state.toolCallsByID[functionCall.callID] {
                    guard previous.name == functionCall.name, previous.argumentsRaw == functionCall.argumentsRaw else {
                        throw AgentRuntimeError(code: .responsesToolCallConflict, message: "A repeated tool call ID changed its arguments.")
                    }
                    return .none
                }
                state.toolCallsByID[functionCall.callID] = functionCall
                logger.info(
                    .tools,
                    "Received tool call from backend.",
                    metadata: [
                        "thread_id": threadID,
                        "turn_id": turnID,
                        "tool_name": functionCall.name
                    ]
                )
                if tools.contains(where: \.supportsParallelExecution) {
                    state.pendingFunctionCalls.append(functionCall)
                } else {
                    try await handleFunctionCall(functionCall, state: &state)
                }
                return .toolCall

            case let .imageGenerationCall(imageGenerationCall):
                guard let image = imageGenerationCall.imageAttachment else {
                    return .none
                }
                try await handleAssistantMessage(
                    AgentMessage(
                        id: item.rawValue.objectValue?["id"]?.stringValue ?? UUID().uuidString,
                        threadID: "",
                        role: .assistant,
                        text: imageGenerationCall.assistantText,
                        images: [image]
                    ),
                    state: &state
                )
                return .assistantMessage

            case .webSearchCall, .other:
                return .none
            }

        case let .structuredOutputPartial(value):
            try await continuation.yield(.structuredOutputPartial(value))
            return .assistantDelta

        case let .structuredOutputCommitted(value):
            try await continuation.yield(.structuredOutputCommitted(value))
            return .assistantMessage

        case let .structuredOutputValidationFailed(validationFailure):
            try await continuation.yield(.structuredOutputValidationFailed(validationFailure))
            return .assistantDelta

        case let .completed(usage, _):
            try await resolvePendingFunctionCalls(state: &state)
            state.aggregateUsage.inputTokens += usage.inputTokens
            state.aggregateUsage.cachedInputTokens += usage.cachedInputTokens
            state.aggregateUsage.outputTokens += usage.outputTokens
            commitCompletedPass(state: &state)
            logger.debug(
                .network,
                "Backend stream completed pass.",
                metadata: [
                    "thread_id": threadID,
                    "turn_id": turnID,
                    "input_tokens": "\(usage.inputTokens)",
                    "output_tokens": "\(usage.outputTokens)"
                ]
            )
            return .none

        case .other:
            return .none
        }
    }

    func handleAssistantTextDelta(
        _ delta: String,
        state: inout TurnRunState
    ) async throws -> Bool {
        guard responseContract?.streamedRequest != nil else {
            guard !delta.isEmpty else {
                return false
            }
            try await continuation.yield(
                .assistantMessageDelta(
                    threadID: threadID,
                    turnID: turnID,
                    delta: delta
                )
            )
            return true
        }

        var emittedVisibleDelta = false
        for parsedEvent in try state.structuredParser.consume(delta: delta) {
            switch parsedEvent {
            case let .visibleText(visibleDelta):
                guard !visibleDelta.isEmpty else {
                    continue
                }
                emittedVisibleDelta = true
                try await continuation.yield(
                    .assistantMessageDelta(
                        threadID: threadID,
                        turnID: turnID,
                        delta: visibleDelta
                    )
                )
            case let .structuredOutputPartial(value):
                emittedVisibleDelta = true
                try await continuation.yield(.structuredOutputPartial(value))
            case let .structuredOutputValidationFailed(validationFailure):
                emittedVisibleDelta = true
                try await continuation.yield(.structuredOutputValidationFailed(validationFailure))
            }
        }
        return emittedVisibleDelta
    }

    func handleAssistantMessage(
        _ messageTemplate: AgentMessage,
        state: inout TurnRunState
    ) async throws {
        let normalizedMessage = try await normalizedAssistantMessage(
            from: messageTemplate,
            state: &state
        )
        let assistantText = resolvedAssistantText(
            for: normalizedMessage,
            fallbackTexts: state.pendingToolFallbackTexts
        )
        let mergedImages = (normalizedMessage.images + state.pendingToolImages).uniqued()
        let message = AgentMessage(
            id: normalizedMessage.id,
            threadID: threadID,
            role: .assistant,
            text: assistantText,
            images: mergedImages,
            phase: normalizedMessage.phase,
            structuredOutput: state.pendingStructuredOutputMetadata
                ?? CodexResponsesBackend.structuredMetadata(
                    from: assistantText,
                    responseFormat: responseContract?.textFormat
                )
        )

        try await continuation.yield(.assistantMessageCompleted(message))
        state.pendingToolImages.removeAll(keepingCapacity: true)
        state.pendingToolFallbackTexts.removeAll(keepingCapacity: true)
        state.pendingStructuredOutputMetadata = nil
    }

    func normalizedAssistantMessage(
        from messageTemplate: AgentMessage,
        state: inout TurnRunState
    ) async throws -> AgentMessage {
        guard let streamedStructuredOutput = responseContract?.streamedRequest else {
            return AgentMessage(
                id: messageTemplate.id,
                threadID: threadID,
                role: .assistant,
                text: messageTemplate.text,
                images: messageTemplate.images,
                phase: messageTemplate.phase
            )
        }

        let extraction = state.structuredParser.finalize(rawMessage: messageTemplate.text)

        switch extraction.finalResult {
        case .none:
            break
        case let .committed(value):
            state.pendingStructuredOutputMetadata = AgentStructuredOutputMetadata(
                formatName: streamedStructuredOutput.responseFormat.name,
                payload: value
            )
            try await continuation.yield(.structuredOutputCommitted(value))
        case let .invalid(validationFailure):
            try await continuation.yield(.structuredOutputValidationFailed(validationFailure))
            throw AgentRuntimeError.structuredOutputInvalid(
                stage: validationFailure.stage,
                underlyingMessage: validationFailure.message
            )
        }

        return AgentMessage(
            id: messageTemplate.id,
            threadID: threadID,
            role: .assistant,
            text: extraction.visibleText,
            images: messageTemplate.images,
                phase: messageTemplate.phase
        )
    }

    func resolvedAssistantText(
        for message: AgentMessage,
        fallbackTexts: [String]
    ) -> String {
        let trimmed = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty, !fallbackTexts.isEmpty else {
            return message.text
        }
        return fallbackTexts.joined(separator: "\n\n")
    }

    func handleFunctionCall(
        _ functionCall: FunctionCallRecord,
        state: inout TurnRunState
    ) async throws {
        let invocation = ToolInvocation(
            id: functionCall.callID,
            threadID: threadID,
            turnID: turnID,
            toolName: functionCall.name,
            arguments: functionCall.arguments
        )

        try await pendingToolResults.register([invocation])
        try await continuation.yield(.toolCallRequested(invocation))
        try await collectToolResult(invocation, state: &state)
    }

    func collectToolResult(_ invocation: ToolInvocation, state: inout TurnRunState) async throws {
        logger.debug(
            .tools,
            "Waiting for tool result submission.",
            metadata: [
                "thread_id": threadID,
                "turn_id": turnID,
                "invocation_id": invocation.id,
                "tool_name": invocation.toolName
            ]
        )
        let toolResult = try await pendingToolResults.wait(for: invocation.id)
        let toolImages = await toolOutputAdapter.images(from: toolResult)
        state.pendingToolImages.append(contentsOf: toolImages)
        state.pendingToolImages = state.pendingToolImages.uniqued()

        if let text = toolResult.combinedText?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            state.pendingToolFallbackTexts.append(text)
        }

        state.pendingToolOutputs.append(
            .functionCallOutput(
                callID: invocation.id,
                output: toolOutputAdapter.text(from: toolResult)
            )
        )
        logger.debug(
            .tools,
            "Recorded tool result for follow-up backend pass.",
            metadata: [
                "thread_id": threadID,
                "turn_id": turnID,
                "invocation_id": invocation.id,
                "tool_name": invocation.toolName,
                "success": "\(toolResult.success)"
            ]
        )
    }

    func commitCompletedPass(state: inout TurnRunState) {
        let completedItems = state.pendingResponseItems
            .sorted { lhs, rhs in
                if lhs.outputIndex == rhs.outputIndex {
                    if let lhsSequenceNumber = lhs.sequenceNumber,
                       let rhsSequenceNumber = rhs.sequenceNumber,
                       lhsSequenceNumber != rhsSequenceNumber
                    {
                        return lhsSequenceNumber < rhsSequenceNumber
                    }
                    return lhs.arrivalOrder < rhs.arrivalOrder
                }
                return lhs.outputIndex < rhs.outputIndex
            }
            .map { WorkingHistoryItem.raw($0.value) }

        state.workingHistory.append(contentsOf: completedItems)
        state.workingHistory.append(contentsOf: state.pendingToolOutputs)

        state.pendingResponseItems.removeAll(keepingCapacity: true)
        state.pendingToolOutputs.removeAll(keepingCapacity: true)
    }

    func emitPendingAssistantFallbackIfNeeded(
        state: inout TurnRunState
    ) async throws {
        guard !state.pendingToolImages.isEmpty || !state.pendingToolFallbackTexts.isEmpty else {
            return
        }

        let message = AgentMessage(
            id: "\(turnID):tool-fallback",
            threadID: threadID,
            role: .assistant,
            text: state.pendingToolFallbackTexts.joined(separator: "\n\n"),
            images: state.pendingToolImages
        )
        state.workingHistory.append(.assistantMessage(message))
        try await continuation.yield(.assistantMessageCompleted(message))
        state.pendingToolImages.removeAll(keepingCapacity: true)
        state.pendingToolFallbackTexts.removeAll(keepingCapacity: true)
    }

    func retryDecision(
        _ error: Error,
        attempt: Int,
        policy: RequestRetryPolicy,
        retryState: RetryAttemptState
    ) -> RetryDecision {
        let hasAttemptsRemaining = attempt < policy.maxAttempts
        let retryableError = streamClient.shouldRetry(error, policy: policy)

        if retryState.hasVisibleOutput {
            return RetryDecision(
                shouldRetry: false,
                retryableError: retryableError,
                blockedBy: "output_already_emitted"
            )
        }

        if !hasAttemptsRemaining {
            return RetryDecision(
                shouldRetry: false,
                retryableError: retryableError,
                blockedBy: "max_attempts_reached"
            )
        }

        if !retryableError {
            return RetryDecision(
                shouldRetry: false,
                retryableError: false,
                blockedBy: "non_retryable_error"
            )
        }

        return RetryDecision(
            shouldRetry: true,
            retryableError: true,
            blockedBy: nil
        )
    }

    func sleepBeforeRetry(
        attempt: Int,
        policy: RequestRetryPolicy,
        error: Error
    ) async throws {
        let delay = max(policy.delayBeforeRetry(attempt: attempt), (error as? AgentRuntimeError)?.http?.retryAfter ?? 0)
        guard delay > 0 else {
            return
        }
        try await Task.sleep(for: .seconds(min(delay, 86_400)))
    }
}
