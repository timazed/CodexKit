import Foundation

extension CodexResponsesBackend: AgentBackendContextCompacting {
    public func compactContext(
        thread: AgentThread,
        effectiveHistory: [AgentMessage],
        instructions: String,
        tools: [ToolDefinition],
        session: ChatGPTSession
    ) async throws -> AgentCompactionResult {
        try await compactContext(thread: thread, effectiveHistory: effectiveHistory, providerContext: nil,
            instructions: instructions, tools: tools, session: session)
    }

    public func compactContext(
        thread: AgentThread,
        effectiveHistory: [AgentMessage],
        providerContext: AgentProviderContext?,
        instructions: String,
        tools: [ToolDefinition],
        session: ChatGPTSession
    ) async throws -> AgentCompactionResult {
        try Task.checkCancellation()
        let settings = thread.configuration ?? configuration.defaultThreadConfiguration
        let providerState = CodexResponsesProviderState(context: providerContext)
        try providerState?.validateClientManagedState()
        let restored: [JSONValue]
        if let items = providerState?.items, !items.isEmpty {
            restored = try CodexResponsesImageReferences.restore(items,
                using: CodexResponsesImageReferences.attachments(in: effectiveHistory))
        } else {
            restored = effectiveHistory.map { WorkingHistoryItem.visibleMessage($0).jsonValue }
        }
        let input = try await CodexResponsesImageAvailability.prepare(restored,
            checker: configuration.imageAvailabilityChecker)
        let factory = CodexResponsesRequestFactory(configuration: configuration, encoder: encoder,
            supportsImageDetailOriginal: supportsImageDetailOriginal(for: settings.model, session: session))
        logger.info(.compaction, "Starting streamed remote context compaction.",
            metadata: ["thread_id": thread.id, "history_count": "\(effectiveHistory.count)"])
        let transport = CodexResponsesCompactionTransport(configuration: configuration,
            urlSession: urlSession, decoder: decoder, logger: logger,
            rateLimitObserver: { snapshots in
                await self.rateLimitStore.update(snapshots, accountID: session.binding.cacheKey)
            })
        let compacted = try await transport.compact(input: input) { input in
            try factory.buildURLRequest(threadConfiguration: settings,
                instructions: instructions, responseContract: nil, threadID: thread.id,
                items: (input + [.object(["type": ResponsesItemType.compactionTrigger.jsonValue])]).map(WorkingHistoryItem.raw),
                tools: tools, session: session, isCompaction: true)
        }
        try Task.checkCancellation()
        let result = try CodexResponsesCompactedHistory.build(input: compacted.input, compaction: compacted.checkpoint, threadID: thread.id)
        logger.info(.compaction, "Remote context compaction completed.",
            metadata: ["thread_id": thread.id, "message_count_after": "\(result.effectiveMessages.count)"])
        return result
    }
}

extension CodexResponsesBackend: AgentBackendProviderContextCompacting {}
