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

        guard let thread = thread(for: threadID) else {
            throw AgentRuntimeError.threadNotFound(threadID)
        }

        let storesTurnState = !request.isEphemeral
        let userMessage = storesTurnState
            ? makeVisibleUserMessage(for: request, in: threadID)
            : nil

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

            Task {
                do {
                    let session = try await self.sessionManager.requireSession()
                    let resolvedTurnSkills = try self.resolveTurnSkills(
                        thread: thread,
                        message: request
                    )
                    let resolvedInstructions = await self.resolveInstructions(
                        thread: thread,
                        message: request,
                        resolvedTurnSkills: resolvedTurnSkills
                    )
                    let tools = await self.toolRegistry.allDefinitions()
                    if storesTurnState {
                        try await self.maybeCompactThreadContextBeforeTurn(
                            thread: thread,
                            request: request,
                            instructions: resolvedInstructions,
                            tools: tools,
                            session: session
                        )
                    }
                    let turnStart = try await self.beginTurnWithUnauthorizedRecovery(
                        thread: thread,
                        history: storesTurnState ? self.effectiveHistory(for: threadID) : [],
                        message: request,
                        instructions: resolvedInstructions,
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
        }
    }

    public func send(
        _ request: Request,
        in threadID: String
    ) async throws -> String {
        let stream = try await streamRequest(
            request,
            in: threadID,
            responseContract: nil
        )
        let message = try await collectFinalAssistantMessage(from: stream)
        return message.displayText
    }

    public func send<Output: AgentStructuredOutput>(
        _ request: Request,
        in threadID: String,
        response outputType: Output.Type = Output.self,
        decoder: JSONDecoder = JSONDecoder()
    ) async throws -> Output {
        try await send(
            request,
            in: threadID,
            response: outputType,
            responseContract: AgentResponseContract(
                format: outputType.responseFormat,
                deliveryMode: .oneShot
            ),
            decoder: decoder
        )
    }

    func send<Output: Decodable & Sendable>(
        _ request: Request,
        in threadID: String,
        response outputType: Output.Type,
        responseContract: AgentResponseContract,
        decoder: JSONDecoder = JSONDecoder()
    ) async throws -> Output {
        let stream = try await streamRequest(
            request,
            in: threadID,
            responseContract: responseContract
        )
        let message = try await collectFinalAssistantMessage(from: stream)
        let payload = Data(message.text.trimmingCharacters(in: .whitespacesAndNewlines).utf8)

        do {
            return try decoder.decode(Output.self, from: payload)
        } catch {
            throw AgentRuntimeError.structuredOutputDecodingFailed(
                typeName: String(describing: outputType),
                underlyingMessage: error.localizedDescription
            )
        }
    }

    func streamRequest(
        _ request: Request,
        in threadID: String,
        responseContract: AgentResponseContract?
    ) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        guard request.hasContent else {
            throw AgentRuntimeError.invalidMessageContent()
        }

        guard let thread = thread(for: threadID) else {
            throw AgentRuntimeError.threadNotFound(threadID)
        }

        let storesTurnState = !request.isEphemeral
        let userMessage = storesTurnState
            ? makeVisibleUserMessage(for: request, in: threadID)
            : nil

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

            Task {
                do {
                    let session = try await self.sessionManager.requireSession()
                    let resolvedTurnSkills = try self.resolveTurnSkills(
                        thread: thread,
                        message: request
                    )
                    let resolvedInstructions = await self.resolveInstructions(
                        thread: thread,
                        message: request,
                        resolvedTurnSkills: resolvedTurnSkills
                    )
                    let tools = await self.toolRegistry.allDefinitions()
                    if storesTurnState {
                        try await self.maybeCompactThreadContextBeforeTurn(
                            thread: thread,
                            request: request,
                            instructions: resolvedInstructions,
                            tools: tools,
                            session: session
                        )
                    }
                    let turnStart = try await self.beginTurnWithUnauthorizedRecovery(
                        thread: thread,
                        history: storesTurnState ? self.effectiveHistory(for: threadID) : [],
                        message: request,
                        instructions: resolvedInstructions,
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
                        storesTurnState: storesTurnState,
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
        }
    }

    func beginTurnWithUnauthorizedRecovery(
        thread: AgentThread,
        history: [AgentMessage],
        message: Request,
        instructions: String,
        responseContract: AgentResponseContract?,
        tools: [ToolDefinition],
        session: ChatGPTSession,
        allowsContextCompaction: Bool = true
    ) async throws -> (
        turnStream: any AgentTurnStreaming,
        session: ChatGPTSession
    ) {
        do {
            let beginTurn = try await withUnauthorizedRecovery(
                initialSession: session
            ) { session in
                try await backend.beginTurn(
                    thread: thread,
                    history: history,
                    message: message,
                    instructions: instructions,
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
                instructions: instructions,
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
                try await backend.beginTurn(
                    thread: thread,
                    history: self.effectiveHistory(for: thread.id),
                    message: message,
                    instructions: instructions,
                    responseFormat: responseContract?.textFormat,
                    streamedStructuredOutput: responseContract?.streamedRequest,
                    tools: tools,
                    session: session
                )
            }
            return (beginTurn.result, beginTurn.session)
        }
    }

    // MARK: - Previews

    public func resolvedInstructionsPreview(
        for threadID: String,
        request: Request
    ) async throws -> String {
        guard let thread = thread(for: threadID) else {
            throw AgentRuntimeError.threadNotFound(threadID)
        }

        let resolvedTurnSkills = try resolveTurnSkills(
            thread: thread,
            message: request
        )

        return await resolveInstructions(
            thread: thread,
            message: request,
            resolvedTurnSkills: resolvedTurnSkills
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
        appendHistoryItem(
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
