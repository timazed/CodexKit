import Foundation

extension AgentRuntime {
    struct PreparedTurn {
        let thread: AgentThread
        let request: Request
        let responseContract: AgentResponseContract?
        let execution: AgentActiveTurnExecution?
        let userMessage: AgentMessage?
        let priorHistory: [AgentMessage]
        var storesTurnState: Bool { !request.isEphemeral }
    }

    func prepareTurn(_ request: Request, in threadID: String, responseContract: AgentResponseContract?) async throws -> PreparedTurn {
        try Task.checkCancellation()
        if let responseContract { try AgentJSONSchemaValidator.validateSchema(responseContract.format.schema) }
        guard request.hasContent else { throw AgentRuntimeError.invalidMessageContent() }
        try validateClientRequestID(request.clientRequestID)
        guard let thread = thread(for: threadID) else { throw AgentRuntimeError.threadNotFound(threadID) }
        let execution = request.isEphemeral ? nil : try reserveTurn(in: threadID)
        logger.info(.runtime, "Starting streamed message.", metadata: [
            "thread_id": threadID,
            "text_length": "\(request.text.count)",
            "image_count": "\(request.images.count)",
            "has_context": "\(request.context != nil)",
            "has_options": "\(request.options != nil)",
            "ephemeral": "\(request.isEphemeral)",
            "structured_response": "\(responseContract != nil)",
            "response_format": responseContract?.format.name ?? "",
        ])
        let userMessage = !request.isEphemeral && request.hasVisibleContent
            ? AgentMessage(threadID: threadID, role: .user, text: request.text, images: request.images) : nil
        let prepared = PreparedTurn(thread: thread, request: request, responseContract: responseContract,
            execution: execution, userMessage: userMessage, priorHistory: request.isEphemeral ? [] : effectiveHistory(for: threadID))
        var persistedPreparation = false
        do {
            if let userMessage {
                try await appendMessage(userMessage)
                persistedPreparation = true
            }
            try Task.checkCancellation()
            if prepared.storesTurnState {
                try await setThreadStatus(.streaming, for: threadID)
                persistedPreparation = true
            }
            try Task.checkCancellation()
            return prepared
        } catch {
            if error is CancellationError || Task.isCancelled, prepared.storesTurnState {
                _ = await recordInterruption(in: threadID, turnID: nil, storesTurnState: true,
                    waitForPersistence: persistedPreparation)
            }
            if let execution { releaseTurn(in: threadID, executionID: execution.id) }
            throw error
        }
    }

    func launchTurn<Output: Decodable & Sendable>(
        _ prepared: PreparedTurn,
        control: AgentExecutionControl,
        structured: AgentStructuredTurnConfiguration<Output>?,
        completionCapture: AgentTurnCompletionCapture? = nil,
        oneShotValidation: AgentOneShotResponseValidation? = nil,
        sink: AgentTurnEventSink<Output>
    ) {
        let threadID = prepared.thread.id
        let cancellation = control.cancellation
        let budget = AgentTurnBudget(limits: turnLimits, executionID: prepared.execution?.id)
        let duration = turnLimits.maximumDuration
        let watchdog = Task {
            guard let duration else { return }
            do { try await Task.sleep(for: .seconds(duration)) } catch { return }
            if budget.expire() { cancellation.cancel() }
        }

        let producer = Task {
            let activity = await backgroundActivityProvider.beginActivity(
                named: "CodexKit agent turn", expirationHandler: { cancellation.cancel() }
            )
            defer {
                control.finish()
                budget.finish()
                watchdog.cancel()
                activity.end()
                cancellation.clear()
                if let execution = prepared.execution { releaseTurn(in: threadID, executionID: execution.id) }
            }
            do {
                try Task.checkCancellation()
                async let initialEvents: Void = emitInitialEvents(prepared, sink: sink)
                let session = try await sessionManager.requireSession()
                let skills = try resolveTurnSkills(thread: prepared.thread, message: prepared.request)
                let instructions = try await resolveInstructions(thread: prepared.thread,
                    message: prepared.request, resolvedTurnSkills: skills)
                let registrations = await toolRegistry.snapshot()
                let tools = registrations.values.map(\.definition).sorted { $0.name < $1.name }
                if prepared.storesTurnState {
                    try await maybeCompactThreadContextBeforeTurn(thread: prepared.thread, request: prepared.request,
                        priorHistory: prepared.priorHistory, pendingUserMessage: prepared.userMessage,
                        resolvedInstructions: instructions, resolvedTurnSkills: skills, tools: tools, session: session)
                }
                let start = try await beginTurnWithUnauthorizedRecovery(
                    thread: prepared.thread,
                    history: prepared.storesTurnState
                        ? historyBeforePendingMessage(in: threadID, pendingUserMessage: prepared.userMessage) : [],
                    providerContext: prepared.storesTurnState ? providerContext(for: threadID) : nil,
                    message: prepared.request, resolvedInstructions: instructions, resolvedTurnSkills: skills,
                    pendingUserMessage: prepared.userMessage, responseContract: prepared.responseContract,
                    tools: tools, session: session, allowsContextCompaction: prepared.storesTurnState)
                control.install(start.turnStream)
                await control.readiness.resolve(.success(()))
                try await initialEvents
                if let execution = prepared.execution, activeTurnExecutions[threadID]?.id == execution.id {
                    activeTurnExecutions[threadID]?.stream = start.turnStream
                }
                try Task.checkCancellation()
                await consumeTurnStream(start.turnStream, for: threadID, userMessage: prepared.userMessage,
                    session: start.session, budget: budget, control: control, registrations: registrations, resolvedTurnSkills: skills, resolvedInstructions: instructions,
                    clientRequestID: prepared.request.clientRequestID, storesTurnState: prepared.storesTurnState,
                    completionCapture: completionCapture, structured: structured,
                    oneShotValidation: oneShotValidation, continuation: sink)
            } catch {
                await control.readiness.resolve(.failure(budget.error ?? error))
                await finishFailedTurn(error, in: threadID, turnID: nil, storesTurnState: prepared.storesTurnState, budget: budget, control: control, sink: sink)
            }
        }
        if Task.isCancelled { cancellation.cancel() }
        cancellation.install { producer.cancel() }
        sink.onCancellation { cancellation.cancel() }
    }

    private func emitInitialEvents<Output>(_ prepared: PreparedTurn, sink: AgentTurnEventSink<Output>) async throws {
        if let message = prepared.userMessage { try await sink.yield(.messageCommitted(message)) }
        if prepared.storesTurnState {
            try await sink.yield(.threadStatusChanged(threadID: prepared.thread.id, status: .streaming))
        }
    }

    func finishFailedTurn<Output>(
        _ originalError: Error, in threadID: String, turnID: String?, storesTurnState: Bool,
        budget: AgentTurnBudget, control: AgentExecutionControl, sink: AgentTurnEventSink<Output>
    ) async {
        control.finish()
        let limitError = budget.error
        let error: Error = limitError ?? originalError
        budget.finish()
        if limitError == nil, error is CancellationError || Task.isCancelled {
            let interruption = await recordInterruption(in: threadID, turnID: turnID, storesTurnState: storesTurnState)
            let events: [AgentEvent] = (storesTurnState ? [.threadStatusChanged(threadID: threadID, status: .idle)] : [])
                + [.turnInterrupted(interruption)]
            if let id = budget.executionID { releaseTurn(in: threadID, executionID: id) }
            sink.finish(throwing: CancellationError(), events: events)
            return
        }
        let runtimeError = (error as? AgentRuntimeError) ?? AgentRuntimeError(code: "turn_failed", message: error.localizedDescription)
        if storesTurnState {
            _ = try? appendHistoryItem(.systemEvent(.init(type: .turnFailed, threadID: threadID,
                turnID: turnID, error: runtimeError, occurredAt: Date())), threadID: threadID, createdAt: Date())
            try? setLatestTurnStatus(.failed, for: threadID)
            try? setPendingState(nil, for: threadID)
            try? setLatestPartialStructuredOutput(nil, for: threadID)
            try? await setThreadStatus(.failed, for: threadID)
        }
        logger.error(.runtime, "Turn failed.", metadata: ["thread_id": threadID, "turn_id": turnID ?? "", "error": runtimeError.message])
        let events: [AgentEvent] = (storesTurnState ? [.threadStatusChanged(threadID: threadID, status: .failed)] : [])
            + [.turnFailed(runtimeError)]
        if let id = budget.executionID { releaseTurn(in: threadID, executionID: id) }
        sink.finish(throwing: error, events: events)
    }
}
