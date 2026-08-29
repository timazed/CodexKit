import Foundation

extension CodexResponsesTurnRunner {
    func handleStreamEvent(
        _ event: CodexResponsesStreamEvent,
        state: inout TurnRunState
    ) async throws -> StreamEventResult {
        switch event.kind {
        case .responseCreated:
            return .none

        case let .assistantTextDelta(delta):
            let emittedDelta = try handleAssistantTextDelta(delta, state: &state)
            return emittedDelta ? .assistantDelta : .none

        case let .outputItem(item, outputIndex):
            state.pendingResponseItems.append(
                PendingResponseItem(
                    outputIndex: outputIndex,
                    sequenceNumber: event.sequenceNumber,
                    arrivalOrder: state.pendingResponseItems.count,
                    value: item.rawValue
                )
            )
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
                try handleAssistantMessage(
                    AgentMessage(
                        id: messageItem.id ?? UUID().uuidString,
                        threadID: "",
                        role: .assistant,
                        text: text,
                        images: images
                    ),
                    state: &state
                )
                return .assistantMessage

            case let .functionCall(functionCallItem):
                let functionCall = FunctionCallRecord(
                    name: functionCallItem.name,
                    callID: functionCallItem.callID,
                    argumentsRaw: functionCallItem.arguments
                )
                logger.info(
                    .tools,
                    "Received tool call from backend.",
                    metadata: [
                        "thread_id": threadID,
                        "turn_id": turnID,
                        "tool_name": functionCall.name
                    ]
                )
                try await handleFunctionCall(functionCall, state: &state)
                return .toolCall

            case let .imageGenerationCall(imageGenerationCall):
                guard let image = imageGenerationCall.imageAttachment else {
                    return .none
                }
                try handleAssistantMessage(
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

            case .other:
                return .none
            }

        case let .structuredOutputPartial(value):
            continuation.yield(.structuredOutputPartial(value))
            return .none

        case let .structuredOutputCommitted(value):
            continuation.yield(.structuredOutputCommitted(value))
            return .none

        case let .structuredOutputValidationFailed(validationFailure):
            continuation.yield(.structuredOutputValidationFailed(validationFailure))
            return .none

        case let .completed(usage, responseID):
            state.aggregateUsage.inputTokens += usage.inputTokens
            state.aggregateUsage.cachedInputTokens += usage.cachedInputTokens
            state.aggregateUsage.outputTokens += usage.outputTokens
            try commitCompletedPass(responseID: responseID, state: &state)
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
    ) throws -> Bool {
        guard responseContract?.streamedRequest != nil else {
            guard !delta.isEmpty else {
                return false
            }
            continuation.yield(
                .assistantMessageDelta(
                    threadID: threadID,
                    turnID: turnID,
                    delta: delta
                )
            )
            return true
        }

        var emittedVisibleDelta = false
        for parsedEvent in state.structuredParser.consume(delta: delta) {
            switch parsedEvent {
            case let .visibleText(visibleDelta):
                guard !visibleDelta.isEmpty else {
                    continue
                }
                emittedVisibleDelta = true
                continuation.yield(
                    .assistantMessageDelta(
                        threadID: threadID,
                        turnID: turnID,
                        delta: visibleDelta
                    )
                )
            case let .structuredOutputPartial(value):
                continuation.yield(.structuredOutputPartial(value))
            case let .structuredOutputValidationFailed(validationFailure):
                continuation.yield(.structuredOutputValidationFailed(validationFailure))
            }
        }
        return emittedVisibleDelta
    }

    func handleAssistantMessage(
        _ messageTemplate: AgentMessage,
        state: inout TurnRunState
    ) throws {
        let normalizedMessage = try normalizedAssistantMessage(
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
            structuredOutput: state.pendingStructuredOutputMetadata
                ?? CodexResponsesBackend.structuredMetadata(
                    from: assistantText,
                    responseFormat: responseContract?.textFormat
                )
        )

        continuation.yield(.assistantMessageCompleted(message))
        state.pendingToolImages.removeAll(keepingCapacity: true)
        state.pendingToolFallbackTexts.removeAll(keepingCapacity: true)
        state.pendingStructuredOutputMetadata = nil
    }

    func normalizedAssistantMessage(
        from messageTemplate: AgentMessage,
        state: inout TurnRunState
    ) throws -> AgentMessage {
        guard let streamedStructuredOutput = responseContract?.streamedRequest else {
            return AgentMessage(
                id: messageTemplate.id,
                threadID: threadID,
                role: .assistant,
                text: messageTemplate.text,
                images: messageTemplate.images
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
            continuation.yield(.structuredOutputCommitted(value))
        case let .invalid(validationFailure):
            continuation.yield(.structuredOutputValidationFailed(validationFailure))
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
            images: messageTemplate.images
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

        continuation.yield(.toolCallRequested(invocation))
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

        if let primaryText = toolResult.primaryText?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !primaryText.isEmpty {
            state.pendingToolFallbackTexts.append(primaryText)
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

    func commitCompletedPass(
        responseID: String?,
        state: inout TurnRunState
    ) throws {
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

        switch configuration.stateManagement {
        case .clientManaged:
            state.workingHistory.append(contentsOf: completedItems)
            state.workingHistory.append(contentsOf: state.pendingToolOutputs)

        case .serverManaged:
            guard let responseID, !responseID.isEmpty else {
                throw AgentRuntimeError(
                    code: "responses_server_state_missing_id",
                    message: "The Responses endpoint did not return a response ID required for server-managed state."
                )
            }
            state.previousResponseID = responseID
            state.workingHistory = state.pendingToolOutputs
        }

        state.pendingResponseItems.removeAll(keepingCapacity: true)
        state.pendingToolOutputs.removeAll(keepingCapacity: true)
    }

    func emitPendingAssistantFallbackIfNeeded(
        state: inout TurnRunState
    ) {
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
        if configuration.stateManagement == .clientManaged {
            state.workingHistory.append(.assistantMessage(message))
        }
        continuation.yield(.assistantMessageCompleted(message))
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

        if retryState.hasNonReplayableOutput {
            return RetryDecision(
                shouldRetry: false,
                retryableError: retryableError,
                blockedBy: "non_replayable_output_emitted"
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
        policy: RequestRetryPolicy
    ) async throws {
        let delay = policy.delayBeforeRetry(attempt: attempt)
        guard delay > 0 else {
            return
        }
        let nanoseconds = UInt64((delay * 1_000_000_000).rounded())
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}
