import Foundation

extension AgentRuntime {
    // MARK: - Messaging

    public func streamMessage<Input: Encodable & Sendable>(
        _ request: AgentMessageRequest<Input>,
        in threadID: String,
        encoder: JSONEncoder = JSONEncoder()
    ) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        try await streamMessage(
            request.resolved(encoder: encoder),
            in: threadID
        )
    }

    public func streamMessage(
        _ request: UserMessageRequest,
        in threadID: String
    ) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        try await streamMessage(
            request,
            in: threadID,
            responseFormat: nil,
            streamedStructuredOutput: nil
        )
    }

    public func streamMessage<Output: AgentStructuredOutput>(
        _ request: UserMessageRequest,
        in threadID: String,
        expecting outputType: Output.Type = Output.self,
        options: AgentStructuredStreamingOptions = AgentStructuredStreamingOptions(),
        decoder: JSONDecoder = JSONDecoder()
    ) async throws -> AsyncThrowingStream<AgentStructuredStreamEvent<Output>, Error> {
        try await streamMessage(
            request,
            in: threadID,
            expecting: outputType,
            responseFormat: outputType.responseFormat,
            options: options,
            decoder: decoder
        )
    }

    public func streamMessage<Input: Encodable & Sendable, Output: AgentStructuredOutput>(
        _ request: AgentMessageRequest<Input>,
        in threadID: String,
        expecting outputType: Output.Type = Output.self,
        options: AgentStructuredStreamingOptions = AgentStructuredStreamingOptions(),
        decoder: JSONDecoder = JSONDecoder(),
        encoder: JSONEncoder = JSONEncoder()
    ) async throws -> AsyncThrowingStream<AgentStructuredStreamEvent<Output>, Error> {
        try await streamMessage(
            request.resolved(encoder: encoder),
            in: threadID,
            expecting: outputType,
            options: options,
            decoder: decoder
        )
    }

    public func streamMessage<Output: Decodable & Sendable>(
        _ request: UserMessageRequest,
        in threadID: String,
        expecting outputType: Output.Type,
        responseFormat: AgentStructuredOutputFormat,
        options: AgentStructuredStreamingOptions = AgentStructuredStreamingOptions(),
        decoder: JSONDecoder = JSONDecoder()
    ) async throws -> AsyncThrowingStream<AgentStructuredStreamEvent<Output>, Error> {
        guard request.hasContent else {
            throw AgentRuntimeError.invalidMessageContent()
        }

        guard let thread = thread(for: threadID) else {
            throw AgentRuntimeError.threadNotFound(threadID)
        }

        let userMessage = makeVisibleUserMessage(for: request, in: threadID)

        logger.info(
            .runtime,
            "Starting structured streamed message.",
            metadata: [
                "thread_id": threadID,
                "text_length": "\(request.text.count)",
                "image_count": "\(request.images.count)",
                "has_structured_input": "\(request.structuredInput != nil)",
                "structured_section_count": "\(request.structuredSections.count)",
                "response_format": responseFormat.name
            ]
        )

        if let userMessage {
            try await appendMessage(userMessage)
        }
        try await setThreadStatus(.streaming, for: threadID)

        return AsyncThrowingStream { continuation in
            if let userMessage {
                continuation.yield(.messageCommitted(userMessage))
            }
            continuation.yield(.threadStatusChanged(threadID: threadID, status: .streaming))

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
                    try await self.maybeCompactThreadContextBeforeTurn(
                        thread: thread,
                        request: request,
                        instructions: resolvedInstructions,
                        tools: tools,
                        session: session
                    )
                    let turnStart = try await self.beginTurnWithUnauthorizedRecovery(
                        thread: thread,
                        history: self.effectiveHistory(for: threadID),
                        message: request,
                        instructions: resolvedInstructions,
                        responseFormat: nil,
                        streamedStructuredOutput: AgentStreamedStructuredOutputRequest(
                            responseFormat: responseFormat,
                            options: options
                        ),
                        tools: tools,
                        session: session
                    )
                    await self.consumeStructuredTurnStream(
                        turnStart.turnStream,
                        for: threadID,
                        userMessage: userMessage,
                        session: turnStart.session,
                        resolvedTurnSkills: resolvedTurnSkills,
                        responseFormat: responseFormat,
                        options: options,
                        decoder: decoder,
                        outputType: outputType,
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
                        continuation: continuation
                    )
                }
            }
        }
    }

    public func sendMessage(
        _ request: UserMessageRequest,
        in threadID: String
    ) async throws -> String {
        let stream = try await streamMessage(
            request,
            in: threadID,
            responseFormat: nil,
            streamedStructuredOutput: nil
        )
        let message = try await collectFinalAssistantMessage(from: stream)
        return message.displayText
    }

    public func sendMessage<Input: Encodable & Sendable>(
        _ request: AgentMessageRequest<Input>,
        in threadID: String,
        encoder: JSONEncoder = JSONEncoder()
    ) async throws -> String {
        try await sendMessage(
            request.resolved(encoder: encoder),
            in: threadID
        )
    }

    public func sendMessage<Output: AgentStructuredOutput>(
        _ request: UserMessageRequest,
        in threadID: String,
        expecting outputType: Output.Type = Output.self,
        decoder: JSONDecoder = JSONDecoder()
    ) async throws -> Output {
        try await sendMessage(
            request,
            in: threadID,
            expecting: outputType,
            responseFormat: outputType.responseFormat,
            decoder: decoder
        )
    }

    public func sendMessage<Input: Encodable & Sendable, Output: AgentStructuredOutput>(
        _ request: AgentMessageRequest<Input>,
        in threadID: String,
        expecting outputType: Output.Type = Output.self,
        decoder: JSONDecoder = JSONDecoder(),
        encoder: JSONEncoder = JSONEncoder()
    ) async throws -> Output {
        try await sendMessage(
            request.resolved(encoder: encoder),
            in: threadID,
            expecting: outputType,
            decoder: decoder
        )
    }

    public func sendMessage<Output: Decodable & Sendable>(
        _ request: UserMessageRequest,
        in threadID: String,
        expecting outputType: Output.Type,
        responseFormat: AgentStructuredOutputFormat,
        decoder: JSONDecoder = JSONDecoder()
    ) async throws -> Output {
        let stream = try await streamMessage(
            request,
            in: threadID,
            responseFormat: responseFormat,
            streamedStructuredOutput: nil
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

    func streamMessage(
        _ request: UserMessageRequest,
        in threadID: String,
        responseFormat: AgentStructuredOutputFormat?,
        streamedStructuredOutput: AgentStreamedStructuredOutputRequest?
    ) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        guard request.hasContent else {
            throw AgentRuntimeError.invalidMessageContent()
        }

        guard let thread = thread(for: threadID) else {
            throw AgentRuntimeError.threadNotFound(threadID)
        }

        let userMessage = makeVisibleUserMessage(for: request, in: threadID)

        logger.info(
            .runtime,
            "Starting streamed message.",
            metadata: [
                "thread_id": threadID,
                "text_length": "\(request.text.count)",
                "image_count": "\(request.images.count)",
                "has_structured_input": "\(request.structuredInput != nil)",
                "structured_section_count": "\(request.structuredSections.count)",
                "structured_response": "\(responseFormat != nil || streamedStructuredOutput != nil)"
            ]
        )

        if let userMessage {
            try await appendMessage(userMessage)
        }
        try await setThreadStatus(.streaming, for: threadID)

        return AsyncThrowingStream { continuation in
            if let userMessage {
                continuation.yield(.messageCommitted(userMessage))
            }
            continuation.yield(.threadStatusChanged(threadID: threadID, status: .streaming))

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
                    try await self.maybeCompactThreadContextBeforeTurn(
                        thread: thread,
                        request: request,
                        instructions: resolvedInstructions,
                        tools: tools,
                        session: session
                    )
                    let turnStart = try await self.beginTurnWithUnauthorizedRecovery(
                        thread: thread,
                        history: self.effectiveHistory(for: threadID),
                        message: request,
                        instructions: resolvedInstructions,
                        responseFormat: responseFormat,
                        streamedStructuredOutput: streamedStructuredOutput,
                        tools: tools,
                        session: session
                    )
                    await self.consumeTurnStream(
                        turnStart.turnStream,
                        for: threadID,
                        userMessage: userMessage,
                        session: turnStart.session,
                        resolvedTurnSkills: resolvedTurnSkills,
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
                        continuation: continuation
                    )
                }
            }
        }
    }

    func beginTurnWithUnauthorizedRecovery(
        thread: AgentThread,
        history: [AgentMessage],
        message: UserMessageRequest,
        instructions: String,
        responseFormat: AgentStructuredOutputFormat?,
        streamedStructuredOutput: AgentStreamedStructuredOutputRequest?,
        tools: [ToolDefinition],
        session: ChatGPTSession
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
                    responseFormat: responseFormat,
                    streamedStructuredOutput: streamedStructuredOutput,
                    tools: tools,
                    session: session
                )
            }
            return (beginTurn.result, beginTurn.session)
        } catch {
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
                    responseFormat: responseFormat,
                    streamedStructuredOutput: streamedStructuredOutput,
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
        request: UserMessageRequest
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
        for threadID: String
    ) async -> AgentRuntimeError {
        let runtimeError = runtimeError(for: error)
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
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    ) async {
        let runtimeError = await recordTurnStartupFailure(error, for: threadID)
        continuation.yield(.threadStatusChanged(threadID: threadID, status: .failed))
        continuation.yield(.turnFailed(runtimeError))
        continuation.finish(throwing: error)
    }

    private func handleStructuredTurnStartupFailure<Output>(
        _ error: Error,
        for threadID: String,
        continuation: AsyncThrowingStream<AgentStructuredStreamEvent<Output>, Error>.Continuation
    ) async {
        let runtimeError = await recordTurnStartupFailure(error, for: threadID)
        continuation.yield(.threadStatusChanged(threadID: threadID, status: .failed))
        continuation.yield(.turnFailed(runtimeError))
        continuation.finish(throwing: error)
    }

    private func makeVisibleUserMessage(
        for request: UserMessageRequest,
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
