import Foundation

extension AgentRuntime {
    // MARK: - Memory Previews

    public func memoryQueryPreview(
        for threadID: String,
        request: UserMessageRequest
    ) async throws -> MemoryQueryResult? {
        guard let thread = thread(for: threadID) else {
            throw AgentRuntimeError.threadNotFound(threadID)
        }

        return await resolvedMemoryQuery(
            thread: thread,
            message: request
        )
    }

    // MARK: - Automatic Capture

    func automaticallyCaptureMemoriesIfConfigured(
        for threadID: String,
        userMessage: AgentMessage,
        assistantMessages: [AgentMessage]
    ) async {
        guard let memoryConfiguration,
              let policy = memoryConfiguration.automaticCapturePolicy
        else {
            return
        }

        guard let thread = thread(for: threadID) else {
            return
        }

        if policy.requiresThreadMemoryContext, thread.memoryContext == nil {
            return
        }

        let source: MemoryCaptureSource
        let sourceDescription: String
        switch policy.source {
        case .lastTurn:
            let turnMessages = [userMessage] + assistantMessages.filter { $0.threadID == threadID }
            guard turnMessages.contains(where: { $0.role == .assistant }) else {
                return
            }
            source = .messages(turnMessages)
            sourceDescription = "last_turn"

        case let .threadHistory(maxMessages):
            source = .threadHistory(maxMessages: maxMessages)
            sourceDescription = "thread_history_\(max(1, maxMessages))"
        }

        if let observer = memoryConfiguration.observer {
            await observer.handle(
                event: .captureStarted(
                    threadID: threadID,
                    sourceDescription: sourceDescription
                )
            )
        }

        do {
            let result = try await captureMemories(
                from: source,
                for: threadID,
                options: policy.options
            )
            if let observer = memoryConfiguration.observer {
                await observer.handle(event: .captureSucceeded(threadID: threadID, result: result))
            }
        } catch {
            if let observer = memoryConfiguration.observer {
                await observer.handle(
                    event: .captureFailed(
                        threadID: threadID,
                        message: error.localizedDescription
                    )
                )
            }
        }
    }

    // MARK: - Memory Context

    public func memoryContext(for threadID: String) throws -> AgentMemoryContext? {
        guard let thread = thread(for: threadID) else {
            throw AgentRuntimeError.threadNotFound(threadID)
        }

        return thread.memoryContext
    }

    // MARK: - Memory Writing

    public func memoryWriter(
        defaults: MemoryWriterDefaults = .init()
    ) throws -> MemoryWriter {
        guard let memoryConfiguration else {
            throw AgentRuntimeError.memoryNotConfigured()
        }

        return MemoryWriter(
            store: memoryConfiguration.store,
            defaults: defaults
        )
    }

    public func memoryWriter(
        for threadID: String,
        defaults: MemoryWriterDefaults = .init()
    ) throws -> MemoryWriter {
        guard let thread = thread(for: threadID) else {
            throw AgentRuntimeError.threadNotFound(threadID)
        }

        let inheritedDefaults: MemoryWriterDefaults
        if let memoryContext = thread.memoryContext {
            inheritedDefaults = MemoryWriterDefaults(
                namespace: memoryContext.namespace,
                scope: memoryContext.scopes.count == 1 ? memoryContext.scopes[0] : nil,
                kind: memoryContext.kinds.count == 1 ? memoryContext.kinds[0] : nil,
                tags: memoryContext.tags,
                relatedIDs: memoryContext.relatedIDs
            )
        } else {
            inheritedDefaults = .init()
        }

        return try memoryWriter(
            defaults: defaults.fillingMissingValues(from: inheritedDefaults)
        )
    }

    // MARK: - Memory Capture

    public func captureMemories(
        from source: MemoryCaptureSource = .threadHistory(),
        for threadID: String,
        options: MemoryCaptureOptions = .init(),
        decoder: JSONDecoder = JSONDecoder()
    ) async throws -> MemoryCaptureResult {
        guard let thread = thread(for: threadID) else {
            throw AgentRuntimeError.threadNotFound(threadID)
        }

        let sourceText = formattedMemoryCaptureSource(
            source,
            threadID: threadID
        )
        guard !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return MemoryCaptureResult(
                sourceText: sourceText,
                drafts: [],
                records: []
            )
        }

        let writer = try memoryWriter(
            for: threadID,
            defaults: options.defaults
        )
        let request = UserMessageRequest(
            text: MemoryExtractionDraftResponse.prompt(
                sourceText: sourceText,
                maxMemories: max(1, options.maxMemories)
            )
        )
        let session = try await sessionManager.requireSession()
        let turnStart = try await beginTurnWithUnauthorizedRecovery(
            thread: thread,
            history: [],
            message: request,
            instructions: options.instructions ?? MemoryExtractionDraftResponse.instructions,
            responseFormat: MemoryExtractionDraftResponse.responseFormat(
                maxMemories: max(1, options.maxMemories)
            ),
            tools: [],
            session: session
        )
        let assistantMessage = try await collectFinalAssistantMessage(
            from: turnStart.turnStream
        )
        let payload = Data(assistantMessage.text.trimmingCharacters(in: .whitespacesAndNewlines).utf8)

        let extraction: MemoryExtractionDraftResponse
        do {
            extraction = try decoder.decode(MemoryExtractionDraftResponse.self, from: payload)
        } catch {
            throw AgentRuntimeError.structuredOutputDecodingFailed(
                typeName: "MemoryExtractionDraftResponse",
                underlyingMessage: error.localizedDescription
            )
        }

        let drafts = extraction.memories.map(\.memoryDraft)
        var records: [MemoryRecord] = []
        records.reserveCapacity(drafts.count)
        for draft in drafts {
            if draft.dedupeKey != nil {
                records.append(try await writer.upsert(draft))
            } else {
                records.append(try await writer.put(draft))
            }
        }

        return MemoryCaptureResult(
            sourceText: sourceText,
            drafts: drafts,
            records: records
        )
    }

    // MARK: - Memory Formatting

    func formattedMemoryCaptureSource(
        _ source: MemoryCaptureSource,
        threadID: String
    ) -> String {
        switch source {
        case let .threadHistory(maxMessages):
            let history = Array((state.messagesByThread[threadID] ?? []).suffix(max(1, maxMessages)))
            return formattedMemoryTranscript(from: history)

        case let .messages(messages):
            return formattedMemoryTranscript(from: messages)

        case let .text(text):
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func formattedMemoryTranscript(from messages: [AgentMessage]) -> String {
        messages
            .map { message in
                let role = message.role.rawValue.capitalized
                let text = message.displayText.trimmingCharacters(in: .whitespacesAndNewlines)

                if text.isEmpty, !message.images.isEmpty {
                    return "\(role): [\(message.images.count) image attachment(s)]"
                }

                return "\(role): \(text)"
            }
            .joined(separator: "\n")
    }

    // MARK: - Memory Query Resolution

    func resolvedMemoryQuery(
        thread: AgentThread,
        message: UserMessageRequest
    ) async -> MemoryQueryResult? {
        guard let memoryConfiguration else {
            return nil
        }

        guard let query = resolvedMemoryQuery(
            thread: thread,
            message: message,
            fallbackRanking: memoryConfiguration.defaultRanking,
            fallbackBudget: memoryConfiguration.defaultReadBudget
        ) else {
            return nil
        }

        if let observer = memoryConfiguration.observer {
            await observer.handle(event: .queryStarted(query))
        }

        do {
            let result = try await memoryConfiguration.store.query(query)
            if let observer = memoryConfiguration.observer {
                await observer.handle(event: .querySucceeded(query: query, result: result))
            }
            return result
        } catch {
            if let observer = memoryConfiguration.observer {
                await observer.handle(
                    event: .queryFailed(
                        query: query,
                        message: error.localizedDescription
                    )
                )
            }
            return nil
        }
    }

    func resolvedMemoryQuery(
        thread: AgentThread,
        message: UserMessageRequest,
        fallbackRanking: MemoryRankingWeights,
        fallbackBudget: MemoryReadBudget
    ) -> MemoryQuery? {
        let selection = message.memorySelection
        if selection?.mode == .disable {
            return nil
        }

        let threadContext = thread.memoryContext
        let namespace = selection?.namespace ??
            threadContext?.namespace

        guard let namespace else {
            return nil
        }

        let scopes: [MemoryScope]
        switch selection?.mode ?? .inherit {
        case .append:
            scopes = uniqueScopes((threadContext?.scopes ?? []) + (selection?.scopes ?? []))
        case .replace:
            scopes = selection?.scopes ?? []
        case .disable:
            return nil
        case .inherit:
            if let selection,
               !selection.scopes.isEmpty {
                scopes = selection.scopes
            } else {
                scopes = threadContext?.scopes ?? []
            }
        }

        let kinds = resolvedValues(
            mode: selection?.mode ?? .inherit,
            threadValues: threadContext?.kinds ?? [],
            selectionValues: selection?.kinds ?? []
        )
        let tags = resolvedValues(
            mode: selection?.mode ?? .inherit,
            threadValues: threadContext?.tags ?? [],
            selectionValues: selection?.tags ?? []
        )
        let relatedIDs = resolvedValues(
            mode: selection?.mode ?? .inherit,
            threadValues: threadContext?.relatedIDs ?? [],
            selectionValues: selection?.relatedIDs ?? []
        )

        let recencyWindow = selection?.recencyWindow
            ?? threadContext?.recencyWindow
        let minImportance = selection?.minImportance
            ?? threadContext?.minImportance
        let ranking = selection?.ranking
            ?? threadContext?.ranking
            ?? fallbackRanking
        let budget = resolvedMemoryBudget(
            thread: thread,
            message: message,
            fallback: fallbackBudget
        )
        let text = selection?.text ?? message.text

        return MemoryQuery(
            namespace: namespace,
            scopes: scopes,
            text: text,
            kinds: kinds,
            tags: tags,
            relatedIDs: relatedIDs,
            recencyWindow: recencyWindow,
            minImportance: minImportance,
            ranking: ranking,
            limit: budget.maxItems,
            maxCharacters: budget.maxCharacters,
            includeArchived: false
        )
    }

    func resolvedMemoryBudget(
        thread: AgentThread,
        message: UserMessageRequest,
        fallback: MemoryReadBudget
    ) -> MemoryReadBudget {
        message.memorySelection?.readBudget
            ?? thread.memoryContext?.readBudget
            ?? fallback
    }

    func uniqueScopes(_ scopes: [MemoryScope]) -> [MemoryScope] {
        var seen: Set<MemoryScope> = []
        return scopes.filter { seen.insert($0).inserted }
    }

    func resolvedValues(
        mode: MemorySelectionMode,
        threadValues: [String],
        selectionValues: [String]
    ) -> [String] {
        switch mode {
        case .append:
            return Array(Set(threadValues + selectionValues)).sorted()
        case .replace:
            return selectionValues
        case .disable:
            return []
        case .inherit:
            return selectionValues.isEmpty ? threadValues : selectionValues
        }
    }
}
