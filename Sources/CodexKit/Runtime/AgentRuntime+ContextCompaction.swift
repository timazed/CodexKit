import Foundation

extension AgentRuntime {
    func effectiveHistory(for threadID: String) -> [AgentMessage] {
        state.contextStateByThread[threadID]?.effectiveMessages
            ?? state.messagesByThread[threadID]
            ?? []
    }

    func shouldUseCompaction() -> Bool {
        contextCompactionConfiguration.isEnabled
    }

    func appendEffectiveMessage(_ message: AgentMessage) {
        guard shouldUseCompaction() || state.contextStateByThread[message.threadID] != nil else {
            return
        }

        let current = state.contextStateByThread[message.threadID]
            ?? AgentThreadContextState(
                threadID: message.threadID,
                effectiveMessages: state.messagesByThread[message.threadID] ?? []
            )
        let updated = AgentThreadContextState(
            threadID: current.threadID,
            effectiveMessages: current.effectiveMessages + [message],
            generation: current.generation,
            lastCompactedAt: current.lastCompactedAt,
            lastCompactionReason: current.lastCompactionReason,
            latestMarkerID: current.latestMarkerID
        )
        state.contextStateByThread[message.threadID] = updated
        enqueueStoreOperation(.upsertThreadContextState(threadID: message.threadID, state: updated))
    }

    func maybeCompactThreadContextBeforeTurn(
        thread: AgentThread,
        request: UserMessageRequest,
        instructions: String,
        tools: [ToolDefinition],
        session: ChatGPTSession
    ) async throws {
        guard shouldUseCompaction(),
              contextCompactionConfiguration.mode.supportsAutomatic
        else {
            return
        }

        let threshold = max(1, contextCompactionConfiguration.trigger.estimatedTokenThreshold)
        let estimatedTokens = approximateTokenCount(
            for: effectiveHistory(for: thread.id),
            pendingMessage: request,
            instructions: instructions
        )
        guard estimatedTokens > threshold else {
            return
        }

        _ = try await compactThreadContext(
            id: thread.id,
            reason: .automaticPreTurn,
            instructions: instructions,
            tools: tools,
            session: session
        )
    }

    func maybeCompactThreadContextAfterContextFailure(
        thread: AgentThread,
        request: UserMessageRequest,
        instructions: String,
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

        _ = try await compactThreadContext(
            id: thread.id,
            reason: .automaticRetry,
            instructions: instructions,
            tools: tools,
            session: session
        )
        return true
    }

    @discardableResult
    public func compactThreadContext(id threadID: String) async throws -> AgentThreadContextState {
        guard shouldUseCompaction(),
              contextCompactionConfiguration.mode.supportsManual
        else {
            throw AgentRuntimeError.contextCompactionDisabled()
        }

        guard let thread = thread(for: threadID) else {
            throw AgentRuntimeError.threadNotFound(threadID)
        }

        let session = try await sessionManager.requireSession()
        let tools = await toolRegistry.allDefinitions()
        let resolvedInstructions = await resolveInstructions(
            thread: thread,
            message: UserMessageRequest(text: "", images: []),
            resolvedTurnSkills: ResolvedTurnSkills(
                threadSkills: [],
                turnSkills: [],
                compiledToolPolicy: CompiledSkillToolPolicy(
                    allowedToolNames: nil,
                    requiredToolNames: [],
                    toolSequence: nil,
                    maxToolCalls: nil
                )
            )
        )
        return try await compactThreadContext(
            id: threadID,
            reason: .manual,
            instructions: resolvedInstructions,
            tools: tools,
            session: session
        )
    }

    @discardableResult
    func compactThreadContext(
        id threadID: String,
        reason: AgentContextCompactionReason,
        instructions: String,
        tools: [ToolDefinition],
        session: ChatGPTSession
    ) async throws -> AgentThreadContextState {
        guard shouldUseCompaction() else {
            throw AgentRuntimeError.contextCompactionDisabled()
        }
        guard let thread = thread(for: threadID) else {
            throw AgentRuntimeError.threadNotFound(threadID)
        }

        let current = state.contextStateByThread[threadID]
            ?? AgentThreadContextState(
                threadID: threadID,
                effectiveMessages: state.messagesByThread[threadID] ?? []
            )
        let result = try await performCompaction(
            thread: thread,
            effectiveHistory: current.effectiveMessages,
            instructions: instructions,
            tools: tools,
            session: session
        )

        let markerTime = Date()
        let nextGeneration = current.generation + 1
        let markerPayload = AgentContextCompactionMarker(
            generation: nextGeneration,
            reason: reason,
            effectiveMessageCountBefore: current.effectiveMessages.count,
            effectiveMessageCountAfter: result.effectiveMessages.count,
            debugSummaryPreview: result.summaryPreview
        )
        let markerRecord = AgentHistoryRecord(
            sequenceNumber: state.nextHistorySequenceByThread[threadID]
                ?? ((state.historyByThread[threadID]?.last?.sequenceNumber ?? 0) + 1),
            createdAt: markerTime,
            item: .systemEvent(
                AgentSystemEventRecord(
                    type: .contextCompacted,
                    threadID: threadID,
                    compaction: markerPayload,
                    occurredAt: markerTime
                )
            )
        )

        let updated = AgentThreadContextState(
            threadID: threadID,
            effectiveMessages: result.effectiveMessages,
            generation: nextGeneration,
            lastCompactedAt: markerTime,
            lastCompactionReason: reason,
            latestMarkerID: markerRecord.id
        )
        state.contextStateByThread[threadID] = updated
        enqueueStoreOperation(.upsertThreadContextState(threadID: threadID, state: updated))
        state.historyByThread[threadID, default: []].append(markerRecord)
        state.nextHistorySequenceByThread[threadID] = nextGenerationSequence(afterAppendingTo: threadID)
        enqueueStoreOperation(.appendCompactionMarker(threadID: threadID, marker: markerRecord))
        try await persistState()
        return updated
    }

    private func performCompaction(
        thread: AgentThread,
        effectiveHistory: [AgentMessage],
        instructions: String,
        tools: [ToolDefinition],
        session: ChatGPTSession
    ) async throws -> AgentCompactionResult {
        switch contextCompactionConfiguration.strategy {
        case .preferRemoteThenLocal:
            if let compactingBackend = backend as? any AgentBackendContextCompacting,
               let result = try? await compactingBackend.compactContext(
                   thread: thread,
                   effectiveHistory: effectiveHistory,
                   instructions: instructions,
                   tools: tools,
                   session: session
               ) {
                return result
            }
            return localCompactionResult(for: thread.id, from: effectiveHistory)

        case .remoteOnly:
            guard let compactingBackend = backend as? any AgentBackendContextCompacting else {
                throw AgentRuntimeError.contextCompactionUnsupported()
            }
            return try await compactingBackend.compactContext(
                thread: thread,
                effectiveHistory: effectiveHistory,
                instructions: instructions,
                tools: tools,
                session: session
            )

        case .localOnly:
            return localCompactionResult(for: thread.id, from: effectiveHistory)
        }
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
        pendingMessage: UserMessageRequest?,
        instructions: String
    ) -> Int {
        let historyCharacters = history.reduce(0) { partialResult, message in
            partialResult + message.text.count + (message.images.count * 512)
        }
        let pendingCharacters = (pendingMessage?.text.count ?? 0) + ((pendingMessage?.images.count ?? 0) * 512)
        return max(1, (historyCharacters + pendingCharacters + instructions.count) / 4)
    }

    func isContextPressureError(_ error: Error) -> Bool {
        let message = ((error as? AgentRuntimeError)?.message ?? error.localizedDescription).lowercased()
        return message.contains("context") && message.contains("limit")
            || message.contains("maximum context length")
            || message.contains("too many tokens")
    }

    private func nextGenerationSequence(afterAppendingTo threadID: String) -> Int {
        (state.historyByThread[threadID]?.last?.sequenceNumber ?? 0) + 1
    }
}
