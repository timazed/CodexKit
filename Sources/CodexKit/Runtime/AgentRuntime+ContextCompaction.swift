import Foundation

extension AgentRuntime {
    func effectiveHistory(for threadID: String) -> [AgentMessage] {
        state.contextStateByThread[threadID]?.effectiveMessages
            ?? state.messagesByThread[threadID]
            ?? []
    }

    func providerContext(for threadID: String) -> AgentProviderContext? {
        state.contextStateByThread[threadID]?.providerContext
    }

    func updateProviderContext(
        _ providerContext: AgentProviderContext,
        for threadID: String
    ) {
        let current = state.contextStateByThread[threadID]
            ?? AgentThreadContextState(
                threadID: threadID,
                effectiveMessages: state.messagesByThread[threadID] ?? []
            )
        let updated = AgentThreadContextState(
            threadID: current.threadID,
            effectiveMessages: current.effectiveMessages,
            providerContext: providerContext,
            generation: current.generation,
            lastCompactedAt: current.lastCompactedAt,
            lastCompactionReason: current.lastCompactionReason,
            latestMarkerID: current.latestMarkerID
        )
        state.contextStateByThread[threadID] = updated
        enqueueStoreOperation(.upsertThreadContextState(threadID: threadID, state: updated))
    }

    func shouldUseCompaction() -> Bool {
        contextCompactionConfiguration.isEnabled
    }

    func appendEffectiveMessage(_ message: AgentMessage) {
        let currentEffectiveMessages = state.contextStateByThread[message.threadID]?.effectiveMessages
            ?? Array((state.messagesByThread[message.threadID] ?? []).dropLast())
        let current = state.contextStateByThread[message.threadID]
            ?? AgentThreadContextState(
                threadID: message.threadID,
                effectiveMessages: currentEffectiveMessages
            )
        let candidateEffectiveMessages = current.effectiveMessages + [message]
        let boundedEffectiveMessages = AgentThreadContextWindow.boundedMessages(
            candidateEffectiveMessages,
            policy: threadActivationPolicy,
            requireClosedTurns: false
        )
        let updated = AgentThreadContextState(
            threadID: current.threadID,
            effectiveMessages: boundedEffectiveMessages,
            providerContext: boundedEffectiveMessages == candidateEffectiveMessages
                ? current.providerContext
                : nil,
            generation: current.generation,
            lastCompactedAt: current.lastCompactedAt,
            lastCompactionReason: current.lastCompactionReason,
            latestMarkerID: current.latestMarkerID
        )
        state.contextStateByThread[message.threadID] = updated
        enqueueStoreOperation(.upsertThreadContextState(threadID: message.threadID, state: updated))
    }

    func appendEffectiveToolInteraction(
        invocation: ToolInvocation,
        result: ToolResultEnvelope,
        completedAt: Date = Date()
    ) {
        let resultText = result.combinedText
            ?? result.errorMessage
            ?? (result.success ? "completed" : "failed")
        appendEffectiveMessage(
            AgentMessage(
                id: "tool-interaction:\(invocation.id)",
                threadID: invocation.threadID,
                role: .tool,
                text: "Tool \(invocation.toolName) completed: \(resultText)",
                toolInteraction: AgentToolInteraction(
                    invocation: invocation,
                    result: result
                ),
                createdAt: completedAt
            )
        )
    }

    func maybeCompactThreadContextBeforeTurn(
        thread: AgentThread,
        request: Request,
        priorHistory: [AgentMessage],
        pendingUserMessage: AgentMessage?,
        resolvedInstructions: ResolvedAgentInstructions,
        resolvedTurnSkills: ResolvedTurnSkills,
        tools: [ToolDefinition],
        session: ChatGPTSession
    ) async throws {
        guard shouldUseCompaction(),
              contextCompactionConfiguration.mode.supportsAutomatic
        else {
            return
        }
        guard !priorHistory.isEmpty else { return }

        let threshold = max(1, contextCompactionConfiguration.trigger.estimatedTokenThreshold)
        let estimatedTokens = approximateTokenCount(
            for: priorHistory,
            pendingMessage: request,
            instructions: resolvedInstructions.contextCompactionText
        )
        logger.debug(
            .compaction,
            "Evaluated pre-turn compaction threshold.",
            metadata: [
                "thread_id": thread.id,
                "estimated_tokens": "\(estimatedTokens)",
                "threshold": "\(threshold)"
            ]
        )
        guard estimatedTokens > threshold else {
            return
        }

        _ = try await compactThreadContext(
            id: thread.id,
            reason: .automaticPreTurn,
            resolvedInstructions: resolvedInstructions,
            resolvedTurnSkills: resolvedTurnSkills,
            clientRequestID: request.clientRequestID,
            effectiveHistory: priorHistory,
            pendingUserMessage: pendingUserMessage,
            tools: tools,
            session: session
        )
    }

    func maybeCompactThreadContextAfterContextFailure(
        thread: AgentThread,
        request: Request,
        pendingUserMessage: AgentMessage?,
        resolvedInstructions: ResolvedAgentInstructions,
        resolvedTurnSkills: ResolvedTurnSkills,
        tools: [ToolDefinition],
        session: ChatGPTSession,
        error: Error
    ) async throws -> Bool {
        guard shouldUseCompaction(),
              contextCompactionConfiguration.mode.supportsAutomatic,
              contextCompactionConfiguration.trigger.retryOnContextLimitError,
              isContextPressureError(error)
        else {
            return false
        }

        var historyToCompact = effectiveHistory(for: thread.id)
        if let pendingUserMessage,
           historyToCompact.last?.id == pendingUserMessage.id {
            historyToCompact.removeLast()
        }
        guard !historyToCompact.isEmpty else { return false }

        _ = try await compactThreadContext(
            id: thread.id,
            reason: .automaticRetry,
            resolvedInstructions: resolvedInstructions,
            resolvedTurnSkills: resolvedTurnSkills,
            clientRequestID: request.clientRequestID,
            effectiveHistory: historyToCompact,
            pendingUserMessage: pendingUserMessage,
            tools: tools,
            session: session
        )
        return true
    }

    @discardableResult
    public func compactThreadContext(id threadID: String) async throws -> AgentThreadContextState {
        let operationID = try reserveThreadOperation(in: threadID)
        defer { releaseThreadOperation(in: threadID, id: operationID) }
        guard shouldUseCompaction(),
              contextCompactionConfiguration.mode.supportsManual
        else {
            throw AgentRuntimeError.contextCompactionDisabled()
        }

        guard let thread = thread(for: threadID) else {
            throw AgentRuntimeError.threadNotFound(threadID)
        }

        let session = try await sessionManager.requireSession()
        try validateThreadAuthentication(thread, session: session)
        let tools = await toolRegistry.allDefinitions()
        let request = Request(text: "", images: [])
        let resolvedTurnSkills = try resolveTurnSkills(
            thread: thread,
            message: request
        )
        let resolvedInstructions = try await resolveInstructions(
            thread: thread,
            message: request,
            resolvedTurnSkills: resolvedTurnSkills
        )
        return try await compactThreadContext(
            id: threadID,
            reason: .manual,
            resolvedInstructions: resolvedInstructions,
            resolvedTurnSkills: resolvedTurnSkills,
            clientRequestID: nil,
            tools: tools,
            session: session
        )
    }

    @discardableResult
    func compactThreadContext(
        id threadID: String,
        reason: AgentContextCompactionReason,
        resolvedInstructions: ResolvedAgentInstructions,
        resolvedTurnSkills: ResolvedTurnSkills,
        clientRequestID: String?,
        effectiveHistory historyOverride: [AgentMessage]? = nil,
        pendingUserMessage: AgentMessage? = nil,
        tools: [ToolDefinition],
        session: ChatGPTSession
    ) async throws -> AgentThreadContextState {
        guard shouldUseCompaction() else {
            throw AgentRuntimeError.contextCompactionDisabled()
        }
        guard let thread = thread(for: threadID) else {
            throw AgentRuntimeError.threadNotFound(threadID)
        }

        try validateThreadAuthentication(thread, session: session)
        try await validateActiveAuthentication(session)
        let operationID = threadOperations[threadID]
        let originalContext = state.contextStateByThread[threadID]
        let originalMessages = state.messagesByThread[threadID]
        let current = originalContext
            ?? AgentThreadContextState(
                threadID: threadID,
                effectiveMessages: state.messagesByThread[threadID] ?? []
            )
        let historyToCompact = historyOverride ?? current.effectiveMessages
        logger.info(
            .compaction,
            "Compacting thread context.",
            metadata: [
                "thread_id": threadID,
                "reason": reason.rawValue,
                "effective_message_count": "\(historyToCompact.count)"
            ]
        )
        let compaction = try await performCompaction(
            thread: thread,
            effectiveHistory: historyToCompact,
            instructions: resolvedInstructions.contextCompactionText,
            tools: tools,
            session: session
        )
        try Task.checkCancellation()
        try await validateActiveAuthentication(session)
        guard self.thread(for: threadID) != nil, threadOperations[threadID] == operationID,
              state.contextStateByThread[threadID] == originalContext,
              state.messagesByThread[threadID] == originalMessages else {
            throw AgentRuntimeError(code: "context_changed_during_compaction",
                message: "The thread context changed while compaction was running. Retry compaction with the current context.")
        }
        let boundedCompactedMessages = AgentThreadContextWindow.boundedMessages(
            compaction.result.effectiveMessages,
            policy: threadActivationPolicy,
            requireClosedTurns: false
        )

        let markerTime = Date()
        let nextGeneration = try AgentCounter.incrementing(
            current.generation,
            field: "context generation",
            threadID: threadID
        )
        let effectiveMessages = pendingUserMessage.map {
            AgentThreadContextWindow.boundedMessages(
                boundedCompactedMessages + [$0],
                policy: threadActivationPolicy,
                requireClosedTurns: false
            )
        } ?? boundedCompactedMessages
        let markerPayload = AgentContextCompactionMarker(
            generation: nextGeneration,
            reason: reason,
            effectiveMessageCountBefore: historyToCompact.count,
            effectiveMessageCountAfter: effectiveMessages.count,
            debugSummaryPreview: compaction.result.summaryPreview
        )
        let memoryApplication = compaction.usedInstructions
            ? makeMemoryCompactionApplicationSnapshot(
                resolvedInstructions: resolvedInstructions,
                threadID: threadID,
                generation: nextGeneration,
                reason: reason,
                clientRequestID: clientRequestID,
                resolvedTurnSkills: resolvedTurnSkills
            )
            : nil
        let markerRecord = try appendHistoryItem(
            .systemEvent(
                AgentSystemEventRecord(
                    type: .contextCompacted,
                    threadID: threadID,
                    compaction: markerPayload,
                    memoryApplication: nil,
                    memoryCompactionApplication: memoryApplication,
                    occurredAt: markerTime
                )
            ),
            threadID: threadID,
            createdAt: markerTime,
        )

        let preservesCompactedPrefix = if pendingUserMessage != nil {
            Array(effectiveMessages.dropLast()) == compaction.result.effectiveMessages
        } else {
            effectiveMessages == compaction.result.effectiveMessages
        }
        let updated = AgentThreadContextState(
            threadID: threadID,
            effectiveMessages: effectiveMessages,
            providerContext: preservesCompactedPrefix
                ? compaction.result.providerContext
                : nil,
            generation: nextGeneration,
            lastCompactedAt: markerTime,
            lastCompactionReason: reason,
            latestMarkerID: markerRecord.id
        )
        state.contextStateByThread[threadID] = updated
        enqueueStoreOperation(.upsertThreadContextState(threadID: threadID, state: updated))
        try await persistState()
        notifyMemoryCompactionApplication(memoryApplication)
        logger.info(
            .compaction,
            "Thread context compaction completed.",
            metadata: [
                "thread_id": threadID,
                "reason": reason.rawValue,
                "generation": "\(updated.generation)",
                "effective_message_count_before": "\(historyToCompact.count)",
                "effective_message_count_after": "\(updated.effectiveMessages.count)"
            ]
        )
        return updated
    }

    private func performCompaction(
        thread: AgentThread,
        effectiveHistory: [AgentMessage],
        instructions: String,
        tools: [ToolDefinition],
        session: ChatGPTSession
    ) async throws -> (result: AgentCompactionResult, usedInstructions: Bool) {
        let strategy = contextCompactionConfiguration.strategy
        if strategy != .localOnly {
            let context = providerContext(for: thread.id)
            var encounteredUnauthorized = false
            do {
                let recovered = try await withUnauthorizedRecovery(initialSession: session) { session in
                    do {
                        if let compactingBackend = backend as? any AgentBackendProviderContextCompacting {
                            return try await compactingBackend.compactContext(thread: thread,
                                effectiveHistory: effectiveHistory, providerContext: context,
                                instructions: instructions, tools: tools, session: session)
                        }
                        guard let compactingBackend = backend as? any AgentBackendContextCompacting else {
                            throw AgentRuntimeError.contextCompactionUnsupported()
                        }
                        return try await compactingBackend.compactContext(thread: thread,
                            effectiveHistory: effectiveHistory, instructions: instructions, tools: tools, session: session)
                    } catch {
                        encounteredUnauthorized = encounteredUnauthorized || (Self.isUnauthorizedError(error) || (error as? AgentRuntimeError)?.http?.statusCode == 403 || error is ChatGPTSessionError)
                        throw error
                    }
                }
                return (recovered.result, true)
            } catch {
                try preserveCompactionCancellation(error)
                if strategy == .remoteOnly || encounteredUnauthorized { throw error }
            }
        }
        return (localCompactionResult(for: thread.id, from: effectiveHistory), false)
    }

    private func preserveCompactionCancellation(_ error: Error) throws {
        if error is CancellationError {
            throw error
        }
        try Task.checkCancellation()
    }

    private func localCompactionResult(
        for threadID: String,
        from history: [AgentMessage]
    ) -> AgentCompactionResult {
        guard history.count > 2 else {
            return AgentCompactionResult(
                effectiveMessages: history,
                summaryPreview: history.last?.displayText
            )
        }

        let lastUser = history.last(where: { $0.role == .user })
        let lastAssistant = history.last(where: { $0.role == .assistant })
        let preservedIDs = Set([lastUser?.id, lastAssistant?.id].compactMap { $0 })
        let summarized = history.filter { !preservedIDs.contains($0.id) }

        let summaryLines = summarized.prefix(12).map { message in
            let role = message.role.rawValue.capitalized
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                return "\(role): \(String(text.prefix(240)))"
            }
            if !message.images.isEmpty {
                return "\(role): [\(message.images.count) image attachment(s)]"
            }
            return "\(role): [empty]"
        }
        let summaryText = """
        Compacted conversation summary:
        \(summaryLines.joined(separator: "\n"))
        """
        let summaryMessage = AgentMessage(
            threadID: threadID,
            role: .system,
            text: summaryText
        )

        var effectiveMessages = [summaryMessage]
        if let lastUser {
            effectiveMessages.append(lastUser)
        }
        if let lastAssistant, lastAssistant.id != lastUser?.id {
            effectiveMessages.append(lastAssistant)
        }

        return AgentCompactionResult(
            effectiveMessages: effectiveMessages,
            summaryPreview: summaryLines.first
        )
    }

    func approximateTokenCount(
        for history: [AgentMessage],
        pendingMessage: Request?,
        instructions: String
    ) -> Int {
        let historyCharacters = history.reduce(0) { partialResult, message in
            partialResult + message.text.count + (message.images.count * 512)
        }
        let pendingStructuredCharacters = pendingMessage.map { message in
            let contextCharacters = message.context?.payload.prettyJSONString.count ?? 0
            let optionsModeCharacters = message.options?.mode.count ?? 0
            let optionRequirementCharacters = message.options?.requirements.reduce(0) { partialResult, requirement in
                partialResult + requirement.count
            } ?? 0
            return contextCharacters + optionsModeCharacters + optionRequirementCharacters
        } ?? 0
        let pendingCharacters = (pendingMessage?.text.count ?? 0)
            + ((pendingMessage?.images.count ?? 0) * 512)
            + pendingStructuredCharacters
        return max(1, (historyCharacters + pendingCharacters + instructions.count) / 4)
    }

    func isContextPressureError(_ error: Error) -> Bool {
        if let code = (error as? AgentRuntimeError)?.http?.providerCode {
            return ["context_length_exceeded", "context_window_exceeded", "context_limit_exceeded", "too_many_tokens"].contains(code)
        }
        let message = ((error as? AgentRuntimeError)?.message ?? error.localizedDescription).lowercased()
        return message.contains("context") && message.contains("limit")
            || message.contains("maximum context length")
            || message.contains("too many tokens")
    }
}
