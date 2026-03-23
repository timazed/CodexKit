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
        var currentTurnID: String?

        do {
            for try await backendEvent in turnStream.events {
                switch backendEvent {
                case let .turnStarted(turn):
                    currentTurnID = turn.id
                    appendHistoryItem(
                        .systemEvent(
                            AgentSystemEventRecord(
                                type: .turnStarted,
                                threadID: threadID,
                                turnID: turn.id,
                                occurredAt: turn.startedAt
                            )
                        ),
                        threadID: threadID,
                        createdAt: turn.startedAt
                    )
                    try setLatestTurnStatus(.running, for: threadID)
                    updateThreadTimestamp(turn.startedAt, for: threadID)
                    try await persistState()
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
                    appendHistoryItem(
                        .toolCall(
                            AgentToolCallRecord(
                                invocation: invocation,
                                requestedAt: Date()
                            )
                        ),
                        threadID: invocation.threadID,
                        createdAt: Date()
                    )
                    try setLatestToolState(
                        latestToolState(for: invocation, result: nil, updatedAt: Date()),
                        for: invocation.threadID
                    )
                    updateThreadTimestamp(Date(), for: invocation.threadID)
                    try await persistState()
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
                        appendHistoryItem(
                            .systemEvent(
                                AgentSystemEventRecord(
                                    type: .turnFailed,
                                    threadID: threadID,
                                    turnID: currentTurnID,
                                    error: completionError,
                                    occurredAt: Date()
                                )
                            ),
                            threadID: threadID,
                            createdAt: Date()
                        )
                        try setLatestTurnStatus(.failed, for: threadID)
                        try setLatestPartialStructuredOutput(nil, for: threadID)
                        try await setThreadStatus(.failed, for: threadID)
                        continuation.yield(.threadStatusChanged(threadID: threadID, status: .failed))
                        continuation.yield(.turnFailed(completionError))
                        continuation.finish(throwing: completionError)
                        return
                    }

                    appendHistoryItem(
                        .systemEvent(
                            AgentSystemEventRecord(
                                type: .turnCompleted,
                                threadID: threadID,
                                turnID: summary.turnID,
                                turnSummary: summary,
                                occurredAt: summary.completedAt
                            )
                        ),
                        threadID: threadID,
                        createdAt: summary.completedAt
                    )
                    try setLatestTurnStatus(.completed, for: threadID)
                    try setLatestPartialStructuredOutput(nil, for: threadID)
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
            appendHistoryItem(
                .systemEvent(
                    AgentSystemEventRecord(
                        type: .turnFailed,
                        threadID: threadID,
                        turnID: currentTurnID,
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
        var currentTurnID: String?

        do {
            for try await backendEvent in turnStream.events {
                switch backendEvent {
                case let .turnStarted(turn):
                    currentTurnID = turn.id
                    appendHistoryItem(
                        .systemEvent(
                            AgentSystemEventRecord(
                                type: .turnStarted,
                                threadID: threadID,
                                turnID: turn.id,
                                occurredAt: turn.startedAt
                            )
                        ),
                        threadID: threadID,
                        createdAt: turn.startedAt
                    )
                    try setLatestTurnStatus(.running, for: threadID)
                    updateThreadTimestamp(turn.startedAt, for: threadID)
                    try await persistState()
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
                        if let currentTurnID {
                            try setLatestPartialStructuredOutput(
                                AgentPartialStructuredOutputSnapshot(
                                    turnID: currentTurnID,
                                    formatName: responseFormat.name,
                                    payload: value,
                                    updatedAt: Date()
                                ),
                                for: threadID
                            )
                            updateThreadTimestamp(Date(), for: threadID)
                            try await persistState()
                        }
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
                        let metadata = AgentStructuredOutputMetadata(
                            formatName: responseFormat.name,
                            payload: value
                        )
                        try setLatestStructuredOutputMetadata(metadata, for: threadID)
                        try setLatestPartialStructuredOutput(nil, for: threadID)
                        appendHistoryItem(
                            .structuredOutput(
                                AgentStructuredOutputRecord(
                                    threadID: threadID,
                                    turnID: currentTurnID ?? "",
                                    metadata: metadata,
                                    committedAt: Date()
                                )
                            ),
                            threadID: threadID,
                            createdAt: Date()
                        )
                        updateThreadTimestamp(Date(), for: threadID)
                        try await persistState()
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
                        try? setLatestPartialStructuredOutput(nil, for: threadID)
                        appendHistoryItem(
                            .systemEvent(
                                AgentSystemEventRecord(
                                    type: .turnFailed,
                                    threadID: threadID,
                                    turnID: currentTurnID,
                                    error: runtimeError,
                                    occurredAt: Date()
                                )
                            ),
                            threadID: threadID,
                            createdAt: Date()
                        )
                        try? setLatestTurnStatus(.failed, for: threadID)
                        try await setThreadStatus(.failed, for: threadID)
                        continuation.yield(.threadStatusChanged(threadID: threadID, status: .failed))
                        continuation.yield(.structuredOutputValidationFailed(validationFailure))
                        continuation.yield(.turnFailed(runtimeError))
                        continuation.finish(throwing: runtimeError)
                        return
                    }

                case let .structuredOutputValidationFailed(validationFailure):
                    try? setLatestPartialStructuredOutput(nil, for: threadID)
                    try? await persistState()
                    continuation.yield(.structuredOutputValidationFailed(validationFailure))

                case let .toolCallRequested(invocation):
                    appendHistoryItem(
                        .toolCall(
                            AgentToolCallRecord(
                                invocation: invocation,
                                requestedAt: Date()
                            )
                        ),
                        threadID: invocation.threadID,
                        createdAt: Date()
                    )
                    try setLatestToolState(
                        latestToolState(for: invocation, result: nil, updatedAt: Date()),
                        for: invocation.threadID
                    )
                    updateThreadTimestamp(Date(), for: invocation.threadID)
                    try await persistState()
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
                        appendHistoryItem(
                            .systemEvent(
                                AgentSystemEventRecord(
                                    type: .turnFailed,
                                    threadID: threadID,
                                    turnID: currentTurnID,
                                    error: completionError,
                                    occurredAt: Date()
                                )
                            ),
                            threadID: threadID,
                            createdAt: Date()
                        )
                        try setLatestTurnStatus(.failed, for: threadID)
                        try setLatestPartialStructuredOutput(nil, for: threadID)
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
                        appendHistoryItem(
                            .systemEvent(
                                AgentSystemEventRecord(
                                    type: .turnFailed,
                                    threadID: threadID,
                                    turnID: currentTurnID,
                                    error: runtimeError,
                                    occurredAt: Date()
                                )
                            ),
                            threadID: threadID,
                            createdAt: Date()
                        )
                        try setLatestTurnStatus(.failed, for: threadID)
                        try setLatestPartialStructuredOutput(nil, for: threadID)
                        try await setThreadStatus(.failed, for: threadID)
                        continuation.yield(.threadStatusChanged(threadID: threadID, status: .failed))
                        continuation.yield(.turnFailed(runtimeError))
                        continuation.finish(throwing: runtimeError)
                        return
                    }

                    appendHistoryItem(
                        .systemEvent(
                            AgentSystemEventRecord(
                                type: .turnCompleted,
                                threadID: threadID,
                                turnID: summary.turnID,
                                turnSummary: summary,
                                occurredAt: summary.completedAt
                            )
                        ),
                        threadID: threadID,
                        createdAt: summary.completedAt
                    )
                    try setLatestTurnStatus(.completed, for: threadID)
                    try setLatestPartialStructuredOutput(nil, for: threadID)
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
            appendHistoryItem(
                .systemEvent(
                    AgentSystemEventRecord(
                        type: .turnFailed,
                        threadID: threadID,
                        turnID: currentTurnID,
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

            appendHistoryItem(
                .approval(
                    AgentApprovalRecord(
                        kind: .requested,
                        request: approval,
                        occurredAt: Date()
                    )
                ),
                threadID: invocation.threadID,
                createdAt: Date()
            )
            try setPendingState(
                .approval(
                    AgentPendingApprovalState(
                        request: approval,
                        requestedAt: Date()
                    )
                ),
                for: invocation.threadID
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
            let resolution = ApprovalResolution(
                requestID: approval.id,
                threadID: approval.threadID,
                turnID: approval.turnID,
                decision: decision
            )
            appendHistoryItem(
                .approval(
                    AgentApprovalRecord(
                        kind: .resolved,
                        request: approval,
                        resolution: resolution,
                        occurredAt: resolution.decidedAt
                    )
                ),
                threadID: invocation.threadID,
                createdAt: resolution.decidedAt
            )
            try setPendingState(nil, for: invocation.threadID)
            continuation.yield(
                .approvalResolved(
                    resolution
                )
            )

            guard decision == .approved else {
                let denied = ToolResultEnvelope.denied(invocation: invocation)
                try setLatestToolState(
                    latestToolState(for: invocation, result: denied, updatedAt: resolution.decidedAt),
                    for: invocation.threadID
                )
                appendHistoryItem(
                    .toolResult(
                        AgentToolResultRecord(
                            threadID: invocation.threadID,
                            turnID: invocation.turnID,
                            result: denied,
                            completedAt: resolution.decidedAt
                        )
                    ),
                    threadID: invocation.threadID,
                    createdAt: resolution.decidedAt
                )
                updateThreadTimestamp(resolution.decidedAt, for: invocation.threadID)
                try await persistState()
                return denied
            }
        }

        let toolWaitStartedAt = Date()
        try setPendingState(
            .toolWait(
                AgentPendingToolWaitState(
                    invocationID: invocation.id,
                    turnID: invocation.turnID,
                    toolName: invocation.toolName,
                    startedAt: toolWaitStartedAt
                )
            ),
            for: invocation.threadID
        )
        try setLatestToolState(
            latestToolState(for: invocation, result: nil, updatedAt: toolWaitStartedAt),
            for: invocation.threadID
        )
        try await setThreadStatus(.waitingForToolResult, for: invocation.threadID)
        continuation.yield(
            .threadStatusChanged(
                threadID: invocation.threadID,
                status: .waitingForToolResult
            )
        )

        let result = await toolRegistry.execute(invocation, session: session)
        let resultDate = Date()
        try setLatestToolState(
            latestToolState(for: invocation, result: result, updatedAt: resultDate),
            for: invocation.threadID
        )
        if let session = result.session, !session.isTerminal {
            try setPendingState(
                .toolWait(
                    AgentPendingToolWaitState(
                        invocationID: invocation.id,
                        turnID: invocation.turnID,
                        toolName: invocation.toolName,
                        startedAt: toolWaitStartedAt,
                        sessionID: session.sessionID,
                        sessionStatus: session.status,
                        metadata: session.metadata,
                        resumable: session.resumable
                    )
                ),
                for: invocation.threadID
            )
        } else {
            try setPendingState(nil, for: invocation.threadID)
            appendHistoryItem(
                .toolResult(
                    AgentToolResultRecord(
                        threadID: invocation.threadID,
                        turnID: invocation.turnID,
                        result: result,
                        completedAt: resultDate
                    )
                ),
                threadID: invocation.threadID,
                createdAt: resultDate
            )
        }
        updateThreadTimestamp(resultDate, for: invocation.threadID)
        try await persistState()
        return result
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

            appendHistoryItem(
                .approval(
                    AgentApprovalRecord(
                        kind: .requested,
                        request: approval,
                        occurredAt: Date()
                    )
                ),
                threadID: invocation.threadID,
                createdAt: Date()
            )
            try setPendingState(
                .approval(
                    AgentPendingApprovalState(
                        request: approval,
                        requestedAt: Date()
                    )
                ),
                for: invocation.threadID
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
            let resolution = ApprovalResolution(
                requestID: approval.id,
                threadID: approval.threadID,
                turnID: approval.turnID,
                decision: decision
            )
            appendHistoryItem(
                .approval(
                    AgentApprovalRecord(
                        kind: .resolved,
                        request: approval,
                        resolution: resolution,
                        occurredAt: resolution.decidedAt
                    )
                ),
                threadID: invocation.threadID,
                createdAt: resolution.decidedAt
            )
            try setPendingState(nil, for: invocation.threadID)
            continuation.yield(
                .approvalResolved(
                    resolution
                )
            )

            guard decision == .approved else {
                let denied = ToolResultEnvelope.denied(invocation: invocation)
                try setLatestToolState(
                    latestToolState(for: invocation, result: denied, updatedAt: resolution.decidedAt),
                    for: invocation.threadID
                )
                appendHistoryItem(
                    .toolResult(
                        AgentToolResultRecord(
                            threadID: invocation.threadID,
                            turnID: invocation.turnID,
                            result: denied,
                            completedAt: resolution.decidedAt
                        )
                    ),
                    threadID: invocation.threadID,
                    createdAt: resolution.decidedAt
                )
                updateThreadTimestamp(resolution.decidedAt, for: invocation.threadID)
                try await persistState()
                return denied
            }
        }

        let toolWaitStartedAt = Date()
        try setPendingState(
            .toolWait(
                AgentPendingToolWaitState(
                    invocationID: invocation.id,
                    turnID: invocation.turnID,
                    toolName: invocation.toolName,
                    startedAt: toolWaitStartedAt
                )
            ),
            for: invocation.threadID
        )
        try setLatestToolState(
            latestToolState(for: invocation, result: nil, updatedAt: toolWaitStartedAt),
            for: invocation.threadID
        )
        try await setThreadStatus(.waitingForToolResult, for: invocation.threadID)
        continuation.yield(
            .threadStatusChanged(
                threadID: invocation.threadID,
                status: .waitingForToolResult
            )
        )

        let result = await toolRegistry.execute(invocation, session: session)
        let resultDate = Date()
        try setLatestToolState(
            latestToolState(for: invocation, result: result, updatedAt: resultDate),
            for: invocation.threadID
        )
        if let session = result.session, !session.isTerminal {
            try setPendingState(
                .toolWait(
                    AgentPendingToolWaitState(
                        invocationID: invocation.id,
                        turnID: invocation.turnID,
                        toolName: invocation.toolName,
                        startedAt: toolWaitStartedAt,
                        sessionID: session.sessionID,
                        sessionStatus: session.status,
                        metadata: session.metadata,
                        resumable: session.resumable
                    )
                ),
                for: invocation.threadID
            )
        } else {
            try setPendingState(nil, for: invocation.threadID)
            appendHistoryItem(
                .toolResult(
                    AgentToolResultRecord(
                        threadID: invocation.threadID,
                        turnID: invocation.turnID,
                        result: result,
                        completedAt: resultDate
                    )
                ),
                threadID: invocation.threadID,
                createdAt: resultDate
            )
        }
        updateThreadTimestamp(resultDate, for: invocation.threadID)
        try await persistState()
        return result
    }
}
