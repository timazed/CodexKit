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
            responseFormat: nil
        )
    }

    public func sendMessage(
        _ request: UserMessageRequest,
        in threadID: String
    ) async throws -> String {
        let stream = try await streamMessage(
            request,
            in: threadID,
            responseFormat: nil
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
            responseFormat: responseFormat
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
        responseFormat: AgentStructuredOutputFormat?
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

    // MARK: - Turn Consumption

    private func consumeTurnStream(
        _ turnStream: any AgentTurnStreaming,
        for threadID: String,
        userMessage: AgentMessage,
        session: ChatGPTSession,
        resolvedTurnSkills: ResolvedTurnSkills,
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    ) async {
        let policyTracker: TurnSkillPolicyTracker? = if resolvedTurnSkills.compiledToolPolicy.hasConstraints {
            TurnSkillPolicyTracker(policy: resolvedTurnSkills.compiledToolPolicy)
        } else {
            nil
        }
        var assistantMessages: [AgentMessage] = []

        do {
            for try await backendEvent in turnStream.events {
                switch backendEvent {
                case let .turnStarted(turn):
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
                    try await appendMessage(message)
                    if message.role == .assistant {
                        assistantMessages.append(message)
                    }
                    continuation.yield(.messageCommitted(message))

                case let .toolCallRequested(invocation):
                    continuation.yield(.toolCallStarted(invocation))

                    let result: ToolResultEnvelope
                    if let policyTracker,
                       let validationError = policyTracker.validate(toolName: invocation.toolName) {
                        result = .failure(
                            invocation: invocation,
                            message: validationError.message
                        )
                    } else {
                        let resolvedResult = try await resolveToolInvocation(
                            invocation,
                            session: session,
                            continuation: continuation
                        )
                        result = resolvedResult
                        policyTracker?.recordAccepted(toolName: invocation.toolName)
                    }

                    try await turnStream.submitToolResult(result, for: invocation.id)
                    continuation.yield(.toolCallFinished(result))
                    try await setThreadStatus(.streaming, for: threadID)
                    continuation.yield(.threadStatusChanged(threadID: threadID, status: .streaming))

                case let .turnCompleted(summary):
                    if let completionError = policyTracker?.completionError() {
                        try await setThreadStatus(.failed, for: threadID)
                        continuation.yield(.threadStatusChanged(threadID: threadID, status: .failed))
                        continuation.yield(.turnFailed(completionError))
                        continuation.finish(throwing: completionError)
                        return
                    }

                    try await setThreadStatus(.idle, for: threadID)
                    await automaticallyCaptureMemoriesIfConfigured(
                        for: threadID,
                        userMessage: userMessage,
                        assistantMessages: assistantMessages
                    )
                    continuation.yield(.threadStatusChanged(threadID: threadID, status: .idle))
                    continuation.yield(.turnCompleted(summary))
                }
            }

            continuation.finish()
        } catch {
            let runtimeError = (error as? AgentRuntimeError)
                ?? AgentRuntimeError(
                    code: "turn_failed",
                    message: error.localizedDescription
                )
            try? await setThreadStatus(.failed, for: threadID)
            continuation.yield(.threadStatusChanged(threadID: threadID, status: .failed))
            continuation.yield(.turnFailed(runtimeError))
            continuation.finish(throwing: error)
        }
    }

    private func resolveToolInvocation(
        _ invocation: ToolInvocation,
        session: ChatGPTSession,
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    ) async throws -> ToolResultEnvelope {
        if let definition = await toolRegistry.definition(named: invocation.toolName),
           definition.approvalPolicy == .requiresApproval {
            let approval = ApprovalRequest(
                threadID: invocation.threadID,
                turnID: invocation.turnID,
                toolInvocation: invocation,
                title: "Approve \(invocation.toolName)?",
                message: definition.approvalMessage
                    ?? "This tool requires explicit approval before it can run."
            )

            try await setThreadStatus(.waitingForApproval, for: invocation.threadID)
            continuation.yield(
                .threadStatusChanged(
                    threadID: invocation.threadID,
                    status: .waitingForApproval
                )
            )
            continuation.yield(.approvalRequested(approval))

            let decision = try await approvalCoordinator.requestApproval(approval)
            continuation.yield(
                .approvalResolved(
                    ApprovalResolution(
                        requestID: approval.id,
                        threadID: approval.threadID,
                        turnID: approval.turnID,
                        decision: decision
                    )
                )
            )

            guard decision == .approved else {
                return .denied(invocation: invocation)
            }
        }

        try await setThreadStatus(.waitingForToolResult, for: invocation.threadID)
        continuation.yield(
            .threadStatusChanged(
                threadID: invocation.threadID,
                status: .waitingForToolResult
            )
        )

        return await toolRegistry.execute(invocation, session: session)
    }

    // MARK: - Message Collection

    func collectFinalAssistantMessage(
        from stream: AsyncThrowingStream<AgentEvent, Error>
    ) async throws -> AgentMessage {
        var latestAssistantMessage: AgentMessage?

        for try await event in stream {
            guard case let .messageCommitted(message) = event,
                  message.role == .assistant
            else {
                continue
            }

            latestAssistantMessage = message
        }

        guard let latestAssistantMessage else {
            throw AgentRuntimeError.assistantResponseMissing()
        }

        return latestAssistantMessage
    }

    func collectFinalAssistantMessage(
        from turnStream: any AgentTurnStreaming
    ) async throws -> AgentMessage {
        var latestAssistantMessage: AgentMessage?

        for try await event in turnStream.events {
            switch event {
            case let .assistantMessageCompleted(message):
                if message.role == .assistant {
                    latestAssistantMessage = message
                }

            case let .toolCallRequested(invocation):
                try await turnStream.submitToolResult(
                    .failure(
                        invocation: invocation,
                        message: "Automatic memory capture does not allow tool calls."
                    ),
                    for: invocation.id
                )

            default:
                break
            }
        }

        guard let latestAssistantMessage else {
            throw AgentRuntimeError.assistantResponseMissing()
        }

        return latestAssistantMessage
    }
}
