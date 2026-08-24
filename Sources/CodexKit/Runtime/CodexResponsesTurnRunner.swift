import Foundation

struct CodexResponsesTurnResult: Sendable {
    let usage: AgentUsage
    let providerContext: AgentProviderContext
}

struct CodexResponsesTurnRunner {
    let configuration: CodexResponsesBackendConfiguration
    let logger: AgentLogger
    let instructions: String
    let responseContract: AgentResponseContract?
    let threadConfiguration: AgentThreadConfiguration
    let requestFactory: CodexResponsesRequestFactory
    let streamClient: CodexResponsesEventStreamClient
    let toolOutputAdapter: CodexResponsesToolOutputAdapter
    let threadID: String
    let turnID: String
    let tools: [ToolDefinition]
    let session: ChatGPTSession
    let pendingToolResults: PendingToolResults
    let continuation: AsyncThrowingStream<AgentBackendEvent, Error>.Continuation

    init(
        configuration: CodexResponsesBackendConfiguration,
        logger: AgentLogger,
        instructions: String,
        responseContract: AgentResponseContract?,
        threadConfiguration: AgentThreadConfiguration,
        urlSession: URLSession,
        encoder: JSONEncoder,
        decoder: JSONDecoder,
        threadID: String,
        turnID: String,
        tools: [ToolDefinition],
        session: ChatGPTSession,
        pendingToolResults: PendingToolResults,
        continuation: AsyncThrowingStream<AgentBackendEvent, Error>.Continuation
    ) {
        self.configuration = configuration
        self.logger = logger
        self.instructions = instructions
        self.responseContract = responseContract
        self.threadConfiguration = threadConfiguration
        self.requestFactory = CodexResponsesRequestFactory(configuration: configuration, encoder: encoder)
        self.streamClient = CodexResponsesEventStreamClient(
            urlSession: urlSession,
            decoder: decoder,
            logger: logger
        )
        self.toolOutputAdapter = CodexResponsesToolOutputAdapter(urlSession: urlSession)
        self.threadID = threadID
        self.turnID = turnID
        self.tools = tools
        self.session = session
        self.pendingToolResults = pendingToolResults
        self.continuation = continuation
    }

    func run(
        history: [AgentMessage],
        providerContext: AgentProviderContext?,
        newMessage: Request
    ) async throws -> CodexResponsesTurnResult {
        let runStartedAt = Date()
        logger.debug(
            .network,
            "Starting backend turn runner.",
            metadata: [
                "thread_id": threadID,
                "turn_id": turnID,
                "history_count": "\(history.count)",
                "tool_count": "\(tools.count)"
            ]
        )
        let providerState = CodexResponsesProviderState(context: providerContext)
        var state = TurnRunState(
            workingHistory: initialWorkingHistory(
                history: history,
                providerState: providerState,
                newMessage: newMessage
            ),
            previousResponseID: configuration.stateManagement == .serverManaged
                ? providerState?.previousResponseID
                : nil
        )

        try await runTurnPasses(state: &state)
        emitPendingAssistantFallbackIfNeeded(state: &state)
        logger.info(
            .network,
            "Backend turn runner finished.",
            metadata: [
                "thread_id": threadID,
                "turn_id": turnID,
                "duration_ms": "\(Int(Date().timeIntervalSince(runStartedAt) * 1000))",
                "input_tokens": "\(state.aggregateUsage.inputTokens)",
                "cached_input_tokens": "\(state.aggregateUsage.cachedInputTokens)",
                "output_tokens": "\(state.aggregateUsage.outputTokens)"
            ]
        )
        let updatedProviderState: CodexResponsesProviderState = switch configuration.stateManagement {
        case .clientManaged:
            CodexResponsesProviderState(
                items: state.workingHistory.map(\.jsonValue)
            )
        case .serverManaged:
            CodexResponsesProviderState(
                previousResponseID: state.previousResponseID
            )
        }
        return CodexResponsesTurnResult(
            usage: state.aggregateUsage,
            providerContext: updatedProviderState.agentProviderContext
        )
    }

    private func initialWorkingHistory(
        history: [AgentMessage],
        providerState: CodexResponsesProviderState?,
        newMessage: Request
    ) -> [WorkingHistoryItem] {
        var workingHistory: [WorkingHistoryItem]
        switch configuration.stateManagement {
        case .clientManaged:
            if let items = providerState?.items, !items.isEmpty {
                workingHistory = items.map(WorkingHistoryItem.raw)
            } else {
                workingHistory = workingHistoryItems(from: history)
            }
        case .serverManaged:
            if providerState?.previousResponseID != nil {
                workingHistory = []
            } else if let items = providerState?.items, !items.isEmpty {
                workingHistory = items.map(WorkingHistoryItem.raw)
            } else {
                workingHistory = workingHistoryItems(from: history)
            }
        }
        workingHistory.append(contentsOf: developerMessages(for: newMessage))
        if newMessage.hasVisibleContent {
            workingHistory.append(
                .userMessage(
                    AgentMessage(
                        threadID: threadID,
                        role: .user,
                        text: newMessage.text,
                        images: newMessage.images
                    )
                )
            )
        }
        return workingHistory
    }

    private func workingHistoryItems(
        from history: [AgentMessage]
    ) -> [WorkingHistoryItem] {
        history.flatMap { message -> [WorkingHistoryItem] in
            guard let interaction = message.toolInteraction else {
                return [.visibleMessage(message)]
            }

            return [
                .functionCall(
                    FunctionCallRecord(
                        name: interaction.invocation.toolName,
                        callID: interaction.invocation.id,
                        argumentsRaw: interaction.invocation.arguments.prettyJSONString
                    )
                ),
                .functionCallOutput(
                    callID: interaction.invocation.id,
                    output: toolOutputAdapter.text(from: interaction.result)
                ),
            ]
        }
    }

    private func developerMessages(
        for message: Request
    ) -> [WorkingHistoryItem] {
        var sections: [String] = []

        if let context = message.context {
            sections.append(
                RequestContextTransport(
                    schemaName: context.schemaName,
                    payload: context.payload
                ).formattedText
            )
        }

        if let options = message.options {
            sections.append(
                RequestOptionsTransport(
                    mode: options.mode,
                    requirements: options.requirements
                ).formattedText
            )
        }

        if let streamedStructuredOutput = responseContract?.streamedRequest {
            sections.append(
                StreamedStructuredOutputTransport(
                    responseFormat: streamedStructuredOutput.responseFormat,
                    options: streamedStructuredOutput.options
                ).formattedText
            )
        }

        guard !sections.isEmpty else {
            return []
        }

        return [.developerMessage(sections.joined(separator: "\n\n"))]
    }

    private func runTurnPasses(
        state: inout TurnRunState
    ) async throws {
        var nextPass: TurnPassDisposition = .needsAnotherPass

        while case .needsAnotherPass = nextPass {
            nextPass = try await runTurnPassWithRetry(state: &state)
        }
    }

    private func runTurnPassWithRetry(
        state: inout TurnRunState
    ) async throws -> TurnPassDisposition {
        let retryPolicy = configuration.requestRetryPolicy
        // Build one request per pass. Retries replay the same request, while a new pass
        // is only started after tool output mutates the working history.
        let request = try makeRequest(for: state)
        logger.debug(
            .network,
            "Starting backend turn pass.",
            metadata: [
                "thread_id": threadID,
                "turn_id": turnID,
                "working_items": "\(state.workingHistory.count)"
            ]
        )

        for attempt in 1...retryPolicy.maxAttempts {
            state.beginAttempt()
            var retryState = RetryAttemptState()
            logger.debug(
                .network,
                "Starting backend turn pass attempt.",
                metadata: [
                    "thread_id": threadID,
                    "turn_id": turnID,
                    "attempt": "\(attempt)",
                    "max_attempts": "\(retryPolicy.maxAttempts)"
                ]
            )
            do {
                let disposition = try await consumeEventStream(
                    request: request,
                    state: &state,
                    retryState: &retryState
                )
                logger.debug(
                    .network,
                    "Backend turn pass attempt completed.",
                    metadata: [
                        "thread_id": threadID,
                        "turn_id": turnID,
                        "attempt": "\(attempt)",
                        "needs_another_pass": "\(disposition == .needsAnotherPass)"
                    ]
                )
                return disposition
            } catch {
                let retryDecision = retryDecision(
                    error,
                    attempt: attempt,
                    policy: retryPolicy,
                    retryState: retryState
                )
                guard retryDecision.shouldRetry else {
                    logger.error(
                        .network,
                        "Backend turn pass failed without retry.",
                        metadata: [
                            "thread_id": threadID,
                            "turn_id": turnID,
                            "attempt": "\(attempt)",
                            "max_attempts": "\(retryPolicy.maxAttempts)",
                            "has_visible_output": "\(retryState.hasVisibleOutput)",
                            "has_non_replayable_output": "\(retryState.hasNonReplayableOutput)",
                            "retryable_error": "\(retryDecision.retryableError)",
                            "retry_blocked_by": retryDecision.blockedBy ?? "unknown",
                            "error": error.localizedDescription
                        ]
                    )
                    throw error
                }
                logger.warning(
                    .retry,
                    "Retrying backend turn pass.",
                    metadata: [
                        "thread_id": threadID,
                        "turn_id": turnID,
                        "attempt": "\(attempt)",
                        "max_attempts": "\(retryPolicy.maxAttempts)",
                        "retryable_error": "\(retryDecision.retryableError)",
                        "error": error.localizedDescription
                    ]
                )
                try await sleepBeforeRetry(attempt: attempt, policy: retryPolicy)
            }
        }

        return .completed
    }

    private func makeRequest(
        for state: TurnRunState
    ) throws -> URLRequest {
        try requestFactory.buildURLRequest(
            threadConfiguration: threadConfiguration,
            instructions: instructions,
            responseContract: responseContract,
            threadID: threadID,
            items: state.workingHistory,
            previousResponseID: state.previousResponseID,
            tools: tools,
            session: session
        )
    }

    private func consumeEventStream(
        request: URLRequest,
        state: inout TurnRunState,
        retryState: inout RetryAttemptState
    ) async throws -> TurnPassDisposition {
        let stream = try await streamClient.streamEvents(request: request)
        var passDisposition: TurnPassDisposition = .completed

        for try await event in stream {
            let eventResult = try await handleStreamEvent(event, state: &state)
            passDisposition = passDisposition.merging(with: eventResult.passDisposition)
            retryState.record(eventResult)
            if case .completed = event {
                return passDisposition
            }
        }

        return passDisposition
    }

    private func handleStreamEvent(
        _ event: CodexResponsesStreamEvent,
        state: inout TurnRunState
    ) async throws -> StreamEventResult {
        switch event {
        case let .assistantTextDelta(delta):
            let emittedDelta = try handleAssistantTextDelta(delta, state: &state)
            return emittedDelta ? .assistantDelta : .none

        case let .outputItem(item, outputIndex, sequenceNumber):
            state.pendingResponseItems.append(
                PendingResponseItem(
                    outputIndex: outputIndex,
                    sequenceNumber: sequenceNumber,
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
        }
    }

    private func handleAssistantTextDelta(
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

    private func handleAssistantMessage(
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

    private func normalizedAssistantMessage(
        from messageTemplate: AgentMessage,
        state: inout TurnRunState
    ) throws -> AgentMessage {
        guard let streamedStructuredOutput = responseContract?.streamedRequest else {
            return AgentMessage(
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
            threadID: threadID,
            role: .assistant,
            text: extraction.visibleText,
            images: messageTemplate.images
        )
    }

    private func resolvedAssistantText(
        for message: AgentMessage,
        fallbackTexts: [String]
    ) -> String {
        let trimmed = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty, !fallbackTexts.isEmpty else {
            return message.text
        }
        return fallbackTexts.joined(separator: "\n\n")
    }

    private func handleFunctionCall(
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

    private func commitCompletedPass(
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

    private func emitPendingAssistantFallbackIfNeeded(
        state: inout TurnRunState
    ) {
        guard !state.pendingToolImages.isEmpty || !state.pendingToolFallbackTexts.isEmpty else {
            return
        }

        let message = AgentMessage(
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

    private func retryDecision(
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

    private func sleepBeforeRetry(
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

private enum TurnPassDisposition {
    case needsAnotherPass
    case completed

    func merging(with other: TurnPassDisposition) -> TurnPassDisposition {
        switch (self, other) {
        case (.needsAnotherPass, _), (_, .needsAnotherPass):
            return .needsAnotherPass
        case (.completed, .completed):
            return .completed
        }
    }
}

private struct TurnRunState {
    var workingHistory: [WorkingHistoryItem]
    var previousResponseID: String?
    var aggregateUsage = AgentUsage()
    var pendingResponseItems: [PendingResponseItem] = []
    var pendingToolOutputs: [WorkingHistoryItem] = []
    var pendingToolImages: [AgentImageAttachment] = []
    var pendingToolFallbackTexts: [String] = []
    var structuredParser = CodexResponsesStructuredStreamParser()
    var pendingStructuredOutputMetadata: AgentStructuredOutputMetadata?

    mutating func beginAttempt() {
        pendingResponseItems.removeAll(keepingCapacity: true)
        pendingToolOutputs.removeAll(keepingCapacity: true)
    }
}

private struct PendingResponseItem {
    let outputIndex: Int
    let sequenceNumber: Int?
    let arrivalOrder: Int
    let value: JSONValue
}

private struct RetryAttemptState {
    var hasAssistantDelta = false
    var hasNonReplayableOutput = false

    var hasVisibleOutput: Bool {
        hasAssistantDelta || hasNonReplayableOutput
    }

    mutating func record(_ eventResult: StreamEventResult) {
        hasAssistantDelta = hasAssistantDelta || eventResult.emittedAssistantDelta
        hasNonReplayableOutput = hasNonReplayableOutput || eventResult.emittedNonReplayableOutput
    }
}

private struct RetryDecision {
    let shouldRetry: Bool
    let retryableError: Bool
    let blockedBy: String?
}

private struct StreamEventResult {
    let emittedAssistantDelta: Bool
    let emittedNonReplayableOutput: Bool
    let passDisposition: TurnPassDisposition

    static let none = StreamEventResult(
        emittedAssistantDelta: false,
        emittedNonReplayableOutput: false,
        passDisposition: .completed
    )

    static let assistantDelta = StreamEventResult(
        emittedAssistantDelta: true,
        emittedNonReplayableOutput: false,
        passDisposition: .completed
    )

    static let assistantMessage = StreamEventResult(
        emittedAssistantDelta: false,
        emittedNonReplayableOutput: true,
        passDisposition: .completed
    )

    static let toolCall = StreamEventResult(
        emittedAssistantDelta: false,
        emittedNonReplayableOutput: true,
        passDisposition: .needsAnotherPass
    )
}
