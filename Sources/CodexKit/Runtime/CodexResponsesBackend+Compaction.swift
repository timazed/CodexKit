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
        let input: [JSONValue]
        if let items = providerState?.items, !items.isEmpty {
            input = try CodexResponsesImageReferences.restore(items,
                using: CodexResponsesImageReferences.attachments(in: effectiveHistory))
        } else {
            input = effectiveHistory.map { WorkingHistoryItem.visibleMessage($0).jsonValue }
        }
        let factory = CodexResponsesRequestFactory(configuration: configuration, encoder: encoder,
            supportsImageDetailOriginal: supportsImageDetailOriginal(for: settings.model, session: session))
        let request = try factory.buildURLRequest(threadConfiguration: settings,
            instructions: instructions, responseContract: nil, threadID: thread.id,
            items: (input + [.object(["type": .string("compaction_trigger")])]).map(WorkingHistoryItem.raw),
            tools: tools, session: session, isCompaction: true)
        logger.info(.compaction, "Starting streamed remote context compaction.",
            metadata: ["thread_id": thread.id, "history_count": "\(effectiveHistory.count)"])
        let transport = CodexResponsesCompactionTransport(configuration: configuration,
            urlSession: urlSession, decoder: decoder, logger: logger,
            rateLimitObserver: { snapshots in
                await self.rateLimitStore.update(snapshots, accountID: session.binding.cacheKey)
            })
        let compaction = try await transport.compact(request: request)
        try Task.checkCancellation()
        let result = try CodexResponsesCompactedHistory.build(input: input, compaction: compaction, threadID: thread.id)
        logger.info(.compaction, "Remote context compaction completed.",
            metadata: ["thread_id": thread.id, "message_count_after": "\(result.effectiveMessages.count)"])
        return result
    }
}

extension CodexResponsesBackend: AgentBackendProviderContextCompacting {}
