import Foundation

struct CodexResponsesTurnRunner {
    let configuration: CodexResponsesBackendConfiguration
    let logger: AgentLogger
    let instructions: String
    let responseFormat: AgentStructuredOutputFormat?
    let streamedStructuredOutput: AgentStreamedStructuredOutputRequest?
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
        responseFormat: AgentStructuredOutputFormat?,
        streamedStructuredOutput: AgentStreamedStructuredOutputRequest?,
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
        self.responseFormat = responseFormat
        self.streamedStructuredOutput = streamedStructuredOutput
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
        newMessage: UserMessageRequest
    ) async throws -> AgentUsage {
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
        var state = TurnRunState(
            workingHistory: initialWorkingHistory(history: history, newMessage: newMessage)
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
        return state.aggregateUsage
    }

    private func initialWorkingHistory(
        history: [AgentMessage],
        newMessage: UserMessageRequest
    ) -> [WorkingHistoryItem] {
        var workingHistory = history.map(WorkingHistoryItem.visibleMessage)
        if let structuredContext = structuredInputContextMessage(for: newMessage) {
            workingHistory.append(.developerContext(structuredContext))
        }
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

    private func structuredInputContextMessage(
        for message: UserMessageRequest
    ) -> StructuredInputContextMessage? {
        var blocks: [StructuredInputContextBlock] = []

        if let structuredInput = message.structuredInput {
            blocks.append(
                StructuredInputContextBlock(
                    name: structuredInput.schemaName ?? "structured_input",
                    schemaName: structuredInput.schemaName,
                    payload: structuredInput.payload,
                    isPrimary: true
                )
            )
        }

        blocks.append(
            contentsOf: message.structuredSections.map { section in
                StructuredInputContextBlock(
                    name: section.name,
                    schemaName: section.schemaName,
                    payload: section.payload,
                    isPrimary: false
                )
            }
        )

        guard !blocks.isEmpty else {
            return nil
        }

        return StructuredInputContextMessage(blocks: blocks)
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
                guard shouldRetry(
                    error,
                    attempt: attempt,
                    policy: retryPolicy,
                    retryState: retryState
                ) else {
                    logger.error(
                        .network,
                        "Backend turn pass failed without retry.",
                        metadata: [
                            "thread_id": threadID,
                            "turn_id": turnID,
                            "attempt": "\(attempt)",
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
            instructions: instructions,
            responseFormat: responseFormat,
            streamedStructuredOutput: streamedStructuredOutput,
            threadID: threadID,
            items: state.workingHistory,
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
        }

        return passDisposition
    }

    private func handleStreamEvent(
        _ event: CodexResponsesStreamEvent,
        state: inout TurnRunState
    ) async throws -> StreamEventResult {
        switch event {
        case let .assistantTextDelta(delta):
            try handleAssistantTextDelta(delta, state: &state)
            return .visibleOutput

        case let .assistantMessage(messageTemplate):
            try handleAssistantMessage(messageTemplate, state: &state)
            return .visibleOutput

        case let .structuredOutputPartial(value):
            continuation.yield(.structuredOutputPartial(value))
            return .none

        case let .structuredOutputCommitted(value):
            continuation.yield(.structuredOutputCommitted(value))
            return .none

        case let .structuredOutputValidationFailed(validationFailure):
            continuation.yield(.structuredOutputValidationFailed(validationFailure))
            return .none

        case let .functionCall(functionCall):
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

        case let .completed(usage):
            state.aggregateUsage.inputTokens += usage.inputTokens
            state.aggregateUsage.cachedInputTokens += usage.cachedInputTokens
            state.aggregateUsage.outputTokens += usage.outputTokens
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
    ) throws {
        guard streamedStructuredOutput != nil else {
            continuation.yield(
                .assistantMessageDelta(
                    threadID: threadID,
                    turnID: turnID,
                    delta: delta
                )
            )
            return
        }

        for parsedEvent in state.structuredParser.consume(delta: delta) {
            switch parsedEvent {
            case let .visibleText(visibleDelta):
                guard !visibleDelta.isEmpty else {
                    continue
                }
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
                    responseFormat: responseFormat
                )
        )

        state.workingHistory.append(.assistantMessage(message))
        continuation.yield(.assistantMessageCompleted(message))
        state.pendingToolImages.removeAll(keepingCapacity: true)
        state.pendingToolFallbackTexts.removeAll(keepingCapacity: true)
        state.pendingStructuredOutputMetadata = nil
    }

    private func normalizedAssistantMessage(
        from messageTemplate: AgentMessage,
        state: inout TurnRunState
    ) throws -> AgentMessage {
        guard let streamedStructuredOutput else {
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
        state.workingHistory.append(.functionCall(functionCall))

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

        state.workingHistory.append(
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
        state.workingHistory.append(.assistantMessage(message))
        continuation.yield(.assistantMessageCompleted(message))
        state.pendingToolImages.removeAll(keepingCapacity: true)
        state.pendingToolFallbackTexts.removeAll(keepingCapacity: true)
    }

    private func shouldRetry(
        _ error: Error,
        attempt: Int,
        policy: RequestRetryPolicy,
        retryState: RetryAttemptState
    ) -> Bool {
        !retryState.hasVisibleOutput
            && attempt < policy.maxAttempts
            && streamClient.shouldRetry(error, policy: policy)
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
    var aggregateUsage = AgentUsage()
    var pendingToolImages: [AgentImageAttachment] = []
    var pendingToolFallbackTexts: [String] = []
    var structuredParser = CodexResponsesStructuredStreamParser()
    var pendingStructuredOutputMetadata: AgentStructuredOutputMetadata?
}

private struct RetryAttemptState {
    var hasVisibleOutput = false

    mutating func record(_ eventResult: StreamEventResult) {
        hasVisibleOutput = hasVisibleOutput || eventResult.emittedVisibleOutput
    }
}

private struct StreamEventResult {
    let emittedVisibleOutput: Bool
    let passDisposition: TurnPassDisposition

    static let none = StreamEventResult(
        emittedVisibleOutput: false,
        passDisposition: .completed
    )

    static let visibleOutput = StreamEventResult(
        emittedVisibleOutput: true,
        passDisposition: .completed
    )

    static let toolCall = StreamEventResult(
        emittedVisibleOutput: true,
        passDisposition: .needsAnotherPass
    )
}
