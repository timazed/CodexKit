import Foundation

extension AgentRuntime {
    // MARK: - Messaging

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

        let session = try await sessionManager.requireSession()
        let userMessage = AgentMessage(
            threadID: threadID,
            role: .user,
            text: request.text,
            images: request.images
        )
        let priorMessages = state.messagesByThread[threadID] ?? []
        let resolvedTurnSkills = try resolveTurnSkills(
            thread: thread,
            message: request
        )
        let resolvedInstructions = await resolveInstructions(
            thread: thread,
            message: request,
            resolvedTurnSkills: resolvedTurnSkills
        )

        try await appendMessage(userMessage)
        try await setThreadStatus(.streaming, for: threadID)

        let tools = await toolRegistry.allDefinitions()
        let turnStart = try await beginTurnWithUnauthorizedRecovery(
            thread: thread,
            history: priorMessages,
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
        let turnStream = turnStart.turnStream
        let turnSession = turnStart.session

        return AsyncThrowingStream { continuation in
            continuation.yield(.messageCommitted(userMessage))
            continuation.yield(.threadStatusChanged(threadID: threadID, status: .streaming))

            Task {
                await self.consumeStructuredTurnStream(
                    turnStream,
                    for: threadID,
                    userMessage: userMessage,
                    session: turnSession,
                    resolvedTurnSkills: resolvedTurnSkills,
                    responseFormat: responseFormat,
                    options: options,
                    decoder: decoder,
                    outputType: outputType,
                    continuation: continuation
                )
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

        let session = try await sessionManager.requireSession()
        let userMessage = AgentMessage(
            threadID: threadID,
            role: .user,
            text: request.text,
            images: request.images
        )
        let priorMessages = state.messagesByThread[threadID] ?? []
        let resolvedTurnSkills = try resolveTurnSkills(
            thread: thread,
            message: request
        )
        let resolvedInstructions = await resolveInstructions(
            thread: thread,
            message: request,
            resolvedTurnSkills: resolvedTurnSkills
        )

        try await appendMessage(userMessage)
        try await setThreadStatus(.streaming, for: threadID)

        let tools = await toolRegistry.allDefinitions()
        let turnStart = try await beginTurnWithUnauthorizedRecovery(
            thread: thread,
            history: priorMessages,
            message: request,
            instructions: resolvedInstructions,
            responseFormat: responseFormat,
            streamedStructuredOutput: streamedStructuredOutput,
            tools: tools,
            session: session
        )
        let turnStream = turnStart.turnStream
        let turnSession = turnStart.session

        return AsyncThrowingStream { continuation in
            continuation.yield(.messageCommitted(userMessage))
            continuation.yield(.threadStatusChanged(threadID: threadID, status: .streaming))

            Task {
                await self.consumeTurnStream(
                    turnStream,
                    for: threadID,
                    userMessage: userMessage,
                    session: turnSession,
                    resolvedTurnSkills: resolvedTurnSkills,
                    continuation: continuation
                )
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
}
