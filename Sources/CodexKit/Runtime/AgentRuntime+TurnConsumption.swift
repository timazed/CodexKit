import Foundation

extension AgentRuntime {
    // MARK: - Turn Consumption

    func consumeTurnStream(
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

                case .structuredOutputPartial,
                     .structuredOutputCommitted,
                     .structuredOutputValidationFailed:
                    break

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

    func consumeStructuredTurnStream<Output: Decodable & Sendable>(
        _ turnStream: any AgentTurnStreaming,
        for threadID: String,
        userMessage: AgentMessage,
        session: ChatGPTSession,
        resolvedTurnSkills: ResolvedTurnSkills,
        responseFormat: AgentStructuredOutputFormat,
        options: AgentStructuredStreamingOptions,
        decoder: JSONDecoder,
        outputType: Output.Type,
        continuation: AsyncThrowingStream<AgentStructuredStreamEvent<Output>, Error>.Continuation
    ) async {
        let policyTracker: TurnSkillPolicyTracker? = if resolvedTurnSkills.compiledToolPolicy.hasConstraints {
            TurnSkillPolicyTracker(policy: resolvedTurnSkills.compiledToolPolicy)
        } else {
            nil
        }
        var assistantMessages: [AgentMessage] = []
        var sawStructuredCommit = false

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

                case let .structuredOutputPartial(value):
                    do {
                        let decoded = try decodeStructuredValue(
                            value,
                            as: outputType,
                            decoder: decoder
                        )
                        if options.emitPartials {
                            continuation.yield(.structuredOutputPartial(decoded))
                        }
                    } catch {
                        continuation.yield(
                            .structuredOutputValidationFailed(
                                AgentStructuredOutputValidationFailure(
                                    stage: .partial,
                                    message: error.localizedDescription,
                                    rawPayload: value.prettyJSONString
                                )
                            )
                        )
                    }

                case let .structuredOutputCommitted(value):
                    do {
                        let decoded = try decodeStructuredValue(
                            value,
                            as: outputType,
                            decoder: decoder
                        )
                        sawStructuredCommit = true
                        continuation.yield(.structuredOutputCommitted(decoded))
                    } catch {
                        let validationFailure = AgentStructuredOutputValidationFailure(
                            stage: .committed,
                            message: error.localizedDescription,
                            rawPayload: value.prettyJSONString
                        )
                        let runtimeError = AgentRuntimeError.structuredOutputInvalid(
                            stage: validationFailure.stage,
                            underlyingMessage: validationFailure.message
                        )
                        try await setThreadStatus(.failed, for: threadID)
                        continuation.yield(.threadStatusChanged(threadID: threadID, status: .failed))
                        continuation.yield(.structuredOutputValidationFailed(validationFailure))
                        continuation.yield(.turnFailed(runtimeError))
                        continuation.finish(throwing: runtimeError)
                        return
                    }

                case let .structuredOutputValidationFailed(validationFailure):
                    continuation.yield(.structuredOutputValidationFailed(validationFailure))

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

                    if options.required, !sawStructuredCommit {
                        let runtimeError = AgentRuntimeError.structuredOutputMissing(
                            formatName: responseFormat.name
                        )
                        try await setThreadStatus(.failed, for: threadID)
                        continuation.yield(.threadStatusChanged(threadID: threadID, status: .failed))
                        continuation.yield(.turnFailed(runtimeError))
                        continuation.finish(throwing: runtimeError)
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

    func resolveToolInvocation(
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

    func resolveToolInvocation<Output: Sendable>(
        _ invocation: ToolInvocation,
        session: ChatGPTSession,
        continuation: AsyncThrowingStream<AgentStructuredStreamEvent<Output>, Error>.Continuation
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
}
