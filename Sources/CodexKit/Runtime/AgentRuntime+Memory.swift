import Foundation

extension AgentRuntime {
    // MARK: - Memory Previews

    public func memoryQueryPreview(
        for threadID: String,
        request: Request
    ) async throws -> MemoryQueryResult? {
        guard let thread = thread(for: threadID) else {
            throw AgentRuntimeError.threadNotFound(threadID)
        }

        let outcome = try await resolvedMemoryQueryOutcome(
            thread: thread,
            message: request
        )
        guard case let .resolved(resolution) = outcome else { return nil }
        return resolution.result
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
                category: memoryContext.categories.count == 1 ? memoryContext.categories[0] : nil,
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
        let request = Request(
            text: MemoryExtractionDraftResponse.prompt(
                sourceText: sourceText,
                maxMemories: max(1, options.maxMemories)
            )
        )
        let session = try await sessionManager.requireSession()
        let noSkills = ResolvedTurnSkills(
            threadSkills: [],
            turnSkills: [],
            compiledToolPolicy: CompiledSkillToolPolicy(
                allowedToolNames: nil,
                requiredToolNames: [],
                toolSequence: nil,
                maxToolCalls: nil
            )
        )
        let extractionInstructions = options.instructions
            ?? MemoryExtractionDraftResponse.instructions
        let turnStart = try await beginTurnWithUnauthorizedRecovery(
            thread: thread,
            history: [],
            providerContext: nil,
            message: request,
            resolvedInstructions: ResolvedAgentInstructions(
                text: extractionInstructions,
                contextCompactionText: extractionInstructions,
                memoryResolution: .notApplied(.disabled),
                threadConfiguration: thread.configuration
            ),
            resolvedTurnSkills: noSkills,
            pendingUserMessage: nil,
            responseContract: AgentResponseContract(
                format: MemoryExtractionDraftResponse.responseFormat(
                    maxMemories: max(1, options.maxMemories)
                ),
                deliveryMode: .oneShot
            ),
            tools: [],
            session: session
        )
        let assistantMessage = try await collectFinalAssistantMessage(
            from: turnStart.turnStream,
            for: threadID
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

    struct ResolvedMemoryQuery: Sendable {
        let query: MemoryQuery
        let result: MemoryQueryResult
    }

    enum ResolvedMemoryQueryOutcome: Sendable {
        case resolved(ResolvedMemoryQuery)
        case notApplied(MemoryApplicationOmissionReason)
    }

    func resolvedMemoryQueryOutcome(
        thread: AgentThread,
        message: Request
    ) async throws -> ResolvedMemoryQueryOutcome {
        guard let memoryConfiguration else {
            return .notApplied(.notConfigured)
        }

        guard message.memorySelection?.mode != .disable else {
            return .notApplied(.disabled)
        }

        guard let query = resolvedMemoryQuery(
            thread: thread,
            message: message,
            fallbackRanking: memoryConfiguration.defaultRanking,
            fallbackBudget: memoryConfiguration.defaultReadBudget
        ) else {
            return .notApplied(.noSelectionContext)
        }

        if let observer = memoryConfiguration.observer {
            await observer.handle(event: .queryStarted(query))
        }
        try Task.checkCancellation()

        do {
            try MemoryQueryEngine.validate(query)
            try Task.checkCancellation()
        } catch {
            return try await rejectedMemoryQueryOutcome(
                error,
                query: query,
                observer: memoryConfiguration.observer
            )
        }

        let result: MemoryQueryResult
        do {
            result = try await packedMemoryQuery(
                query,
                store: memoryConfiguration.store
            )
            try Task.checkCancellation()
        } catch {
            if error is CancellationError {
                throw error
            }
            try Task.checkCancellation()
            if let observer = memoryConfiguration.observer {
                await observer.handle(
                    event: .queryFailed(
                        query: query,
                        message: error.localizedDescription
                    )
                )
            }
            try Task.checkCancellation()
            return .notApplied(.unavailable)
        }

        do {
            try AgentStoredPayloadValidator.validateMemoryQueryResult(
                query: query,
                result: result,
                validatesCurrentEligibility: true
            )
            try Task.checkCancellation()
        } catch {
            return try await rejectedMemoryQueryOutcome(
                error,
                query: query,
                observer: memoryConfiguration.observer
            )
        }

        if let observer = memoryConfiguration.observer {
            await observer.handle(event: .querySucceeded(query: query, result: result))
        }
        try Task.checkCancellation()
        return .resolved(ResolvedMemoryQuery(query: query, result: result))
    }

    private func rejectedMemoryQueryOutcome(
        _ error: Error,
        query: MemoryQuery,
        observer: (any MemoryObserving)?
    ) async throws -> ResolvedMemoryQueryOutcome {
        if error is CancellationError {
            throw error
        }
        try Task.checkCancellation()
        if let observer {
            await observer.handle(
                event: .queryFailed(
                    query: query,
                    message: error.localizedDescription
                )
            )
        }
        try Task.checkCancellation()
        return .notApplied(.rejected)
    }

    /// Packing is part of the memory-store query contract. Persistent adapters
    /// perform eligibility, ranking, size skipping, and limiting in the database.
    package func packedMemoryQuery(
        _ query: MemoryQuery,
        store: any MemoryStoring
    ) async throws -> MemoryQueryResult {
        try await store.query(query)
    }

    func resolvedMemoryQuery(
        thread: AgentThread,
        message: Request,
        fallbackRanking: MemoryRankingProfile,
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

        let categories = resolvedValues(
            mode: selection?.mode ?? .inherit,
            threadValues: threadContext?.categories ?? [],
            selectionValues: selection?.categories ?? []
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
        let textMatchPolicy = selection?.textMatchPolicy
            ?? threadContext?.textMatchPolicy
            ?? defaultRuntimeTextMatchPolicy(for: text)

        return MemoryQuery(
            namespace: namespace,
            scopes: scopes,
            text: text,
            textMatchPolicy: textMatchPolicy,
            categories: categories,
            tags: tags,
            relatedIDs: relatedIDs,
            recencyWindow: recencyWindow,
            minImportance: minImportance,
            ranking: ranking,
            limit: budget.maxItems,
            maxCharacters: MemoryQueryEngine.promptContentCharacterLimit(for: budget),
            includeArchived: false
        )
    }

    func resolvedMemoryBudget(
        thread: AgentThread,
        message: Request,
        fallback: MemoryReadBudget
    ) -> MemoryReadBudget {
        message.memorySelection?.readBudget
            ?? thread.memoryContext?.readBudget
            ?? fallback
    }

    /// Two-token matching avoids broad OR searches for normal prompts while a
    /// one-token prompt remains useful. Explicit host policies are never
    /// weakened when the query contains fewer tokens than they require.
    func defaultRuntimeTextMatchPolicy(for text: String?) -> MemoryTextMatchPolicy {
        MemoryQueryEngine.uniqueTokens(text).count >= 2 ? .runtimeDefault : .anyToken
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
