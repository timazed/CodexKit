import Foundation

extension AgentRuntime {
    // MARK: - Messaging

    public func stream(
        _ request: Request,
        in threadID: String
    ) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        try await streamRequest(
            request,
            in: threadID,
            responseContract: nil
        )
    }

    public func stream<Output: AgentStructuredOutput>(
        _ request: Request,
        in threadID: String,
        response outputType: Output.Type = Output.self,
        options: AgentStructuredStreamingOptions = AgentStructuredStreamingOptions(),
        decoder: JSONDecoder = JSONDecoder()
    ) async throws -> AsyncThrowingStream<AgentStructuredStreamEvent<Output>, Error> {
        try await stream(
            request,
            in: threadID,
            response: outputType,
            responseContract: AgentResponseContract(
                format: outputType.responseFormat,
                deliveryMode: .streaming(options: options)
            ),
            options: options,
            decoder: decoder
        )
    }

    func stream<Output: Decodable & Sendable>(
        _ request: Request,
        in threadID: String,
        response outputType: Output.Type,
        responseContract: AgentResponseContract,
        options: AgentStructuredStreamingOptions = AgentStructuredStreamingOptions(),
        decoder: JSONDecoder = JSONDecoder()
    ) async throws -> AsyncThrowingStream<AgentStructuredStreamEvent<Output>, Error> {
        guard request.hasContent else {
            throw AgentRuntimeError.invalidMessageContent()
        }
        try validateClientRequestID(request.clientRequestID)

        guard let thread = thread(for: threadID) else {
            throw AgentRuntimeError.threadNotFound(threadID)
        }

        let storesTurnState = !request.isEphemeral
        let userMessage = storesTurnState
            ? makeVisibleUserMessage(for: request, in: threadID)
            : nil
        let turnHistory = storesTurnState ? effectiveHistory(for: threadID) : []

        logger.info(
            .runtime,
            "Starting structured streamed message.",
            metadata: [
                "thread_id": threadID,
                "text_length": "\(request.text.count)",
                "image_count": "\(request.images.count)",
                "has_context": "\(request.context != nil)",
                "has_options": "\(request.options != nil)",
                "ephemeral": "\(request.isEphemeral)",
                "response_format": responseContract.format.name
            ]
        )

        if let userMessage, storesTurnState {
            try await appendMessage(userMessage)
        }
        if storesTurnState {
            try await setThreadStatus(.streaming, for: threadID)
        }

        return AsyncThrowingStream { continuation in
            if let userMessage {
                continuation.yield(.messageCommitted(userMessage))
            }
            if storesTurnState {
                continuation.yield(.threadStatusChanged(threadID: threadID, status: .streaming))
            }

            let cancellationHandle = AgentTurnCancellationHandle()
            let producerTask = Task {
                let activity = await self.backgroundActivityProvider.beginActivity(
                    named: "CodexKit agent turn",
                    expirationHandler: { cancellationHandle.cancel() }
                )
                defer {
                    activity.end()
                    cancellationHandle.clear()
                }
                do {
                    let session = try await self.sessionManager.requireSession()
                    let resolvedTurnSkills = try self.resolveTurnSkills(
                        thread: thread,
                        message: request
                    )
                    let resolvedInstructions = try await self.resolveInstructions(
                        thread: thread,
                        message: request,
                        resolvedTurnSkills: resolvedTurnSkills
                    )
                    let tools = await self.toolRegistry.allDefinitions()
                    if storesTurnState {
                        try await self.maybeCompactThreadContextBeforeTurn(
                            thread: thread,
                            request: request,
                            priorHistory: turnHistory,
                            pendingUserMessage: userMessage,
                            resolvedInstructions: resolvedInstructions,
                            resolvedTurnSkills: resolvedTurnSkills,
                            tools: tools,
                            session: session
                        )
                    }
                    let turnStart = try await self.beginTurnWithUnauthorizedRecovery(
                        thread: thread,
                        history: storesTurnState
                            ? self.historyBeforePendingMessage(
                                in: threadID,
                                pendingUserMessage: userMessage
                            )
                            : turnHistory,
                        providerContext: storesTurnState ? self.providerContext(for: threadID) : nil,
                        message: request,
                        resolvedInstructions: resolvedInstructions,
                        resolvedTurnSkills: resolvedTurnSkills,
                        pendingUserMessage: userMessage,
                        responseContract: responseContract,
                        tools: tools,
                        session: session,
                        allowsContextCompaction: storesTurnState
                    )
                    await self.consumeStructuredTurnStream(
                        turnStart.turnStream,
                        for: threadID,
                        userMessage: userMessage,
                        session: turnStart.session,
                        resolvedTurnSkills: resolvedTurnSkills,
                        resolvedInstructions: resolvedInstructions,
                        clientRequestID: request.clientRequestID,
                        responseFormat: responseContract.format,
                        options: options,
                        decoder: decoder,
                        outputType: outputType,
                        storesTurnState: storesTurnState,
                        continuation: continuation
                    )
                } catch {
                    self.logger.error(
                        .runtime,
                        "Structured streamed message failed during startup.",
                        metadata: [
                            "thread_id": threadID,
                            "error": error.localizedDescription
                        ]
                    )
                    await self.handleStructuredTurnStartupFailure(
                        error,
                        for: threadID,
                        storesTurnState: storesTurnState,
                        continuation: continuation
                    )
                }
            }
            cancellationHandle.install { producerTask.cancel() }
            continuation.onTermination = { @Sendable termination in
                if case .cancelled = termination {
                    cancellationHandle.cancel()
                }
            }
        }
    }

    func streamRequest(
        _ request: Request,
        in threadID: String,
        responseContract: AgentResponseContract?,
        completionCapture: AgentTurnCompletionCapture? = nil
    ) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        guard request.hasContent else {
            throw AgentRuntimeError.invalidMessageContent()
        }
        try validateClientRequestID(request.clientRequestID)

        guard let thread = thread(for: threadID) else {
            throw AgentRuntimeError.threadNotFound(threadID)
        }

        let storesTurnState = !request.isEphemeral
        let userMessage = storesTurnState
            ? makeVisibleUserMessage(for: request, in: threadID)
            : nil
        let turnHistory = storesTurnState ? effectiveHistory(for: threadID) : []

        logger.info(
            .runtime,
            "Starting streamed message.",
            metadata: [
                "thread_id": threadID,
                "text_length": "\(request.text.count)",
                "image_count": "\(request.images.count)",
                "has_context": "\(request.context != nil)",
                "has_options": "\(request.options != nil)",
                "ephemeral": "\(request.isEphemeral)",
                "structured_response": "\(responseContract != nil)"
            ]
        )

        if let userMessage, storesTurnState {
            try await appendMessage(userMessage)
        }
        if storesTurnState {
            try await setThreadStatus(.streaming, for: threadID)
        }

        return AsyncThrowingStream { continuation in
            if let userMessage {
                continuation.yield(.messageCommitted(userMessage))
            }
            if storesTurnState {
                continuation.yield(.threadStatusChanged(threadID: threadID, status: .streaming))
            }

            let cancellationHandle = AgentTurnCancellationHandle()
            let producerTask = Task {
                let activity = await self.backgroundActivityProvider.beginActivity(
                    named: "CodexKit agent turn",
                    expirationHandler: { cancellationHandle.cancel() }
                )
                defer {
                    activity.end()
                    cancellationHandle.clear()
                }
                do {
                    let session = try await self.sessionManager.requireSession()
                    let resolvedTurnSkills = try self.resolveTurnSkills(
                        thread: thread,
                        message: request
                    )
                    let resolvedInstructions = try await self.resolveInstructions(
                        thread: thread,
                        message: request,
                        resolvedTurnSkills: resolvedTurnSkills
                    )
                    let tools = await self.toolRegistry.allDefinitions()
                    if storesTurnState {
                        try await self.maybeCompactThreadContextBeforeTurn(
                            thread: thread,
                            request: request,
                            priorHistory: turnHistory,
                            pendingUserMessage: userMessage,
                            resolvedInstructions: resolvedInstructions,
                            resolvedTurnSkills: resolvedTurnSkills,
                            tools: tools,
                            session: session
                        )
                    }
                    let turnStart = try await self.beginTurnWithUnauthorizedRecovery(
                        thread: thread,
                        history: storesTurnState
                            ? self.historyBeforePendingMessage(
                                in: threadID,
                                pendingUserMessage: userMessage
                            )
                            : turnHistory,
                        providerContext: storesTurnState ? self.providerContext(for: threadID) : nil,
                        message: request,
                        resolvedInstructions: resolvedInstructions,
                        resolvedTurnSkills: resolvedTurnSkills,
                        pendingUserMessage: userMessage,
                        responseContract: responseContract,
                        tools: tools,
                        session: session,
                        allowsContextCompaction: storesTurnState
                    )
                    await self.consumeTurnStream(
                        turnStart.turnStream,
                        for: threadID,
                        userMessage: userMessage,
                        session: turnStart.session,
                        resolvedTurnSkills: resolvedTurnSkills,
                        resolvedInstructions: resolvedInstructions,
                        clientRequestID: request.clientRequestID,
                        storesTurnState: storesTurnState,
                        completionCapture: completionCapture,
                        continuation: continuation
                    )
                } catch {
                    self.logger.error(
                        .runtime,
                        "Streamed message failed during startup.",
                        metadata: [
                            "thread_id": threadID,
                            "error": error.localizedDescription
                        ]
                    )
                    await self.handleTurnStartupFailure(
                        error,
                        for: threadID,
                        storesTurnState: storesTurnState,
                        continuation: continuation
                    )
                }
            }
            cancellationHandle.install { producerTask.cancel() }
            continuation.onTermination = { @Sendable termination in
                if case .cancelled = termination {
                    cancellationHandle.cancel()
                }
            }
        }
    }

    func beginTurnWithUnauthorizedRecovery(
        thread: AgentThread,
        history: [AgentMessage],
        providerContext: AgentProviderContext?,
        message: Request,
        resolvedInstructions: ResolvedAgentInstructions,
        resolvedTurnSkills: ResolvedTurnSkills,
        pendingUserMessage: AgentMessage?,
        responseContract: AgentResponseContract?,
        tools: [ToolDefinition],
        session: ChatGPTSession,
        allowsContextCompaction: Bool = true
    ) async throws -> (
        turnStream: AgentTurnStream,
        session: ChatGPTSession
    ) {
        do {
            let beginTurn = try await withUnauthorizedRecovery(
                initialSession: session
            ) { session in
                try await self.beginBackendTurn(
                    thread: thread,
                    history: history,
                    providerContext: providerContext,
                    message: message,
                    instructions: resolvedInstructions.text,
                    responseFormat: responseContract?.textFormat,
                    streamedStructuredOutput: responseContract?.streamedRequest,
                    tools: tools,
                    session: session
                )
            }
            return (beginTurn.result, beginTurn.session)
        } catch {
            guard allowsContextCompaction else {
                throw error
            }
            let compacted = try await maybeCompactThreadContextAfterContextFailure(
                thread: thread,
                request: message,
                pendingUserMessage: pendingUserMessage,
                resolvedInstructions: resolvedInstructions,
                resolvedTurnSkills: resolvedTurnSkills,
                tools: tools,
                session: session,
                error: error
            )
            guard compacted else {
                throw error
            }

            let beginTurn = try await withUnauthorizedRecovery(
                initialSession: session
            ) { session in
                try await self.beginBackendTurn(
                    thread: thread,
                    history: self.historyBeforePendingMessage(
                        in: thread.id,
                        pendingUserMessage: pendingUserMessage
                    ),
                    providerContext: self.providerContext(for: thread.id),
                    message: message,
                    instructions: resolvedInstructions.text,
                    responseFormat: responseContract?.textFormat,
                    streamedStructuredOutput: responseContract?.streamedRequest,
                    tools: tools,
                    session: session
                )
            }
            return (beginTurn.result, beginTurn.session)
        }
    }

    private func beginBackendTurn(
        thread: AgentThread,
        history: [AgentMessage],
        providerContext: AgentProviderContext?,
        message: Request,
        instructions: String,
        responseFormat: AgentStructuredOutputFormat?,
        streamedStructuredOutput: AgentStreamedStructuredOutputRequest?,
        tools: [ToolDefinition],
        session: ChatGPTSession
    ) async throws -> AgentTurnStream {
        if let contextBackend = backend as? any AgentBackendProviderContextSupporting {
            return try await contextBackend.beginTurn(
                thread: thread,
                history: history,
                providerContext: providerContext,
                message: message,
                instructions: instructions,
                responseFormat: responseFormat,
                streamedStructuredOutput: streamedStructuredOutput,
                tools: tools,
                session: session
            )
        }
        return try await backend.beginTurn(
            thread: thread,
            history: history,
            message: message,
            instructions: instructions,
            responseFormat: responseFormat,
            streamedStructuredOutput: streamedStructuredOutput,
            tools: tools,
            session: session
        )
    }

    private func runtimeError(for error: Error) -> AgentRuntimeError {
        (error as? AgentRuntimeError)
            ?? AgentRuntimeError(
                code: "turn_failed",
                message: error.localizedDescription
            )
    }

    private func recordTurnStartupFailure(
        _ error: Error,
        for threadID: String,
        storesTurnState: Bool
    ) async -> AgentRuntimeError {
        let runtimeError = runtimeError(for: error)
        guard storesTurnState else {
            return runtimeError
        }
        _ = try? appendHistoryItem(
            .systemEvent(
                AgentSystemEventRecord(
                    type: .turnFailed,
                    threadID: threadID,
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
        return runtimeError
    }

    private func handleTurnStartupFailure(
        _ error: Error,
        for threadID: String,
        storesTurnState: Bool,
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    ) async {
        let runtimeError = await recordTurnStartupFailure(error, for: threadID, storesTurnState: storesTurnState)
        if storesTurnState {
            continuation.yield(.threadStatusChanged(threadID: threadID, status: .failed))
        }
        continuation.yield(.turnFailed(runtimeError))
        continuation.finish(throwing: error)
    }

    private func handleStructuredTurnStartupFailure<Output>(
        _ error: Error,
        for threadID: String,
        storesTurnState: Bool,
        continuation: AsyncThrowingStream<AgentStructuredStreamEvent<Output>, Error>.Continuation
    ) async {
        let runtimeError = await recordTurnStartupFailure(error, for: threadID, storesTurnState: storesTurnState)
        if storesTurnState {
            continuation.yield(.threadStatusChanged(threadID: threadID, status: .failed))
        }
        continuation.yield(.turnFailed(runtimeError))
        continuation.finish(throwing: error)
    }

    private func makeVisibleUserMessage(
        for request: Request,
        in threadID: String
    ) -> AgentMessage? {
        guard request.hasVisibleContent else {
            return nil
        }

        return AgentMessage(
            threadID: threadID,
            role: .user,
            text: request.text,
            images: request.images
        )
    }
}
