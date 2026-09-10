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
    let turnStartedAt: Date
    let request: Request
    let tools: [ToolDefinition]
    let session: ChatGPTSession
    let authenticationContext = AgentAuthenticationContext.current
    let control: CodexTurnControl
    let pendingToolResults: PendingToolResults
    let continuation: AgentEventChannel<AgentBackendEvent>
    let streamReady: @Sendable () async -> Void

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
        turnStartedAt: Date,
        request: Request,
        tools: [ToolDefinition],
        session: ChatGPTSession,
        pendingToolResults: PendingToolResults,
        control: CodexTurnControl = CodexTurnControl(),
        rateLimitObserver: @escaping @Sendable ([AgentRateLimitSnapshot]) async -> Void = { _ in },
        streamReady: @escaping @Sendable () async -> Void = {},
        continuation: AgentEventChannel<AgentBackendEvent>
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
            logger: logger,
            maximumBufferedEvents: configuration.maximumBufferedEvents,
            responseBudget: CodexResponseBudget(maximumBytes: configuration.maximumResponseBytes),
            rateLimitObserver: rateLimitObserver
        )
        self.toolOutputAdapter = CodexResponsesToolOutputAdapter(urlSession: urlSession)
        self.threadID = threadID
        self.turnID = turnID
        self.turnStartedAt = turnStartedAt
        self.request = request
        self.tools = tools
        self.session = session
        self.control = control
        self.pendingToolResults = pendingToolResults
        self.continuation = continuation
        self.streamReady = streamReady
    }

    func run(
        history: [AgentMessage],
        providerContext: AgentProviderContext?
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
        try providerState?.validateClientManagedState()
        var state = TurnRunState(
            workingHistory: try initialWorkingHistory(
                history: history,
                providerState: providerState,
                newMessage: request
            )
        )

        try await runTurnPasses(state: &state)
        try await emitPendingAssistantFallbackIfNeeded(state: &state)
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
        return try turnResult(from: state)
    }

    private func turnResult(
        from state: TurnRunState
    ) throws -> CodexResponsesTurnResult {
        let updatedProviderState = CodexResponsesProviderState(items: try CodexResponsesImageReferences.externalize(
            state.workingHistory.map(\.jsonValue)
        ))
        return CodexResponsesTurnResult(
            usage: state.aggregateUsage,
            providerContext: updatedProviderState.agentProviderContext
        )
    }

    func initialWorkingHistory(
        history: [AgentMessage],
        providerState: CodexResponsesProviderState?,
        newMessage: Request
    ) throws -> [WorkingHistoryItem] {
        var workingHistory: [WorkingHistoryItem]
        if let items = providerState?.items, !items.isEmpty {
            workingHistory = try CodexResponsesImageReferences.restore(
                items,
                using: CodexResponsesImageReferences.attachments(
                    in: history,
                    additional: newMessage.images
                )
            ).map(WorkingHistoryItem.raw)
        } else {
            workingHistory = workingHistoryItems(from: history)
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

    func workingHistoryItems(
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

    func developerMessages(
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

    func runTurnPasses(
        state: inout TurnRunState
    ) async throws {
        var nextPass: TurnPassDisposition = .needsAnotherPass
        var passesRemaining = configuration.maximumModelPasses

        while case .needsAnotherPass = nextPass {
            try Task.checkCancellation()
            if let remaining = passesRemaining {
                guard remaining > 0 else { throw AgentRuntimeError.executionLimitExceeded(.modelPasses) }
                passesRemaining = remaining - 1
            }
            nextPass = try await runTurnPassWithRetry(state: &state)
            let messages = await control.drain(closeIfEmpty: nextPass == .completed)
            if !messages.isEmpty {
                for message in messages {
                    state.workingHistory.append(.userMessage(message))
                    try await continuation.yield(.userMessageAccepted(message))
                }
                nextPass = .needsAnotherPass
            }
        }
    }

    func runTurnPassWithRetry(
        state: inout TurnRunState
    ) async throws -> TurnPassDisposition {
        let retryPolicy = configuration.requestRetryPolicy
        // Build one request per pass. Retries replay the same request, while a new pass
        // is only started after tool output mutates the working history.
        let lease = try await authenticationContext?.resolve() ?? session
        let request = try makeRequest(for: state, session: lease)
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
                let attemptLease = try await authenticationContext?.resolve() ?? lease
                var authenticatedRequest = request
                authenticatedRequest.setValue("Bearer \(attemptLease.accessToken)", forHTTPHeaderField: "Authorization")
                let disposition = try await consumeAuthenticatedStream(
                    request: authenticatedRequest,
                    lease: attemptLease,
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
                    if let error = error as? AgentRuntimeError {
                        throw error.withRetryInformation(.init(attempt: attempt, maximumAttempts: retryPolicy.maxAttempts,
                            isRetryable: retryDecision.retryableError,
                            safety: retryState.hasVisibleOutput ? .outputAlreadyEmitted : .beforeOutput))
                    }
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
                try await sleepBeforeRetry(attempt: attempt, policy: retryPolicy, error: error)
            }
        }

        return .completed
    }

    func makeRequest(
        for state: TurnRunState, session: ChatGPTSession? = nil
    ) throws -> URLRequest {
        try requestFactory.buildURLRequest(
            threadConfiguration: threadConfiguration,
            instructions: instructions,
            responseContract: responseContract,
            threadID: threadID,
            items: state.workingHistory,
            tools: tools,
            session: session ?? self.session
        )
    }

    func consumeEventStream(
        request: URLRequest,
        state: inout TurnRunState,
        retryState: inout RetryAttemptState
    ) async throws -> TurnPassDisposition {
        var passDisposition: TurnPassDisposition = .completed
        let stream = try await streamClient.streamEvents(request: request)
        await streamReady()
        for try await event in stream {
            let eventResult = try await handleStreamEvent(event, state: &state)
            passDisposition = passDisposition.merging(with: eventResult.passDisposition)
            retryState.record(eventResult)
            if case .completed = event.kind {
                return passDisposition
            }
        }
        try Task.checkCancellation()
        throw AgentRuntimeError(
            code: "responses_stream_disconnected",
            message: "The Responses stream closed before response.completed."
        )
    }
}
