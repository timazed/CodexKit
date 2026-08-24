import Foundation

struct ThreadResumePersistenceProjection: Sendable {
    let thread: AgentThread
    let summary: AgentThreadSummary
    let contextState: AgentThreadContextState
    let record: AgentHistoryRecord

    var operations: [AgentStoreWriteOperation] {
        [
            .upsertThread(thread),
            .upsertSummary(threadID: thread.id, summary: summary),
            .upsertThreadContextState(threadID: thread.id, state: contextState),
            .appendHistoryItems(threadID: thread.id, items: [record]),
        ]
    }
}

extension AgentRuntime {
    // MARK: - Threads

    @discardableResult
    public func createThread(
        title: String? = nil,
        configuration: AgentThreadConfiguration? = nil,
        personaStack: AgentPersonaStack? = nil,
        personaSource: AgentDefinitionSource? = nil,
        skillIDs: [String] = [],
        memoryContext: AgentMemoryContext? = nil
    ) async throws -> AgentThread {
        try assertSkillsExist(skillIDs)
        let resolvedPersonaStack: AgentPersonaStack?
        if let personaStack {
            resolvedPersonaStack = personaStack
        } else if let personaSource {
            resolvedPersonaStack = try await definitionSourceLoader.loadPersonaStack(from: personaSource)
        } else {
            resolvedPersonaStack = nil
        }

        let session = try await sessionManager.requireSession()
        logger.info(
            .runtime,
            "Creating thread.",
            metadata: [
                "has_title": "\(title != nil)",
                "skill_count": "\(skillIDs.count)"
            ]
        )
        let creation = try await withUnauthorizedRecovery(
            initialSession: session
        ) { session in
            try await backend.createThread(session: session)
        }
        var thread = creation.result
        if let title {
            thread.title = title
        }
        if let configuration {
            thread.configuration = configuration
        } else if thread.configuration == nil {
            thread.configuration = await backend.defaultThreadConfiguration
        }
        thread.personaStack = resolvedPersonaStack
        thread.skillIDs = skillIDs
        thread.memoryContext = memoryContext
        try await upsertThread(thread, persist: false)
        appendHistoryItem(
            .systemEvent(
                AgentSystemEventRecord(
                    type: .threadCreated,
                    threadID: thread.id,
                    occurredAt: thread.createdAt
                )
            ),
            threadID: thread.id,
            createdAt: thread.createdAt
        )
        updateThreadTimestamp(thread.createdAt, for: thread.id)
        try await persistState()
        logger.info(
            .runtime,
            "Thread created.",
            metadata: ["thread_id": thread.id]
        )
        return thread
    }

    @discardableResult
    public func resumeThread(id: String) async throws -> AgentThread {
        await acquireThreadResume(id)
        defer { releaseThreadResume(id) }

        logger.info(.runtime, "Resuming thread.", metadata: ["thread_id": id])
        let metadata = try await stateStore.prepare()
        lazyThreadActivationEnabled = metadata.capabilities.supportsLazyThreadActivation
        if lazyThreadActivationEnabled, let activeThread = thread(for: id) {
            return activeThread
        }

        var activation = try await stateStore.loadThreadActivationState(
            id: id,
            policy: threadActivationPolicy
        )
        let session = try await sessionManager.requireSession()
        let resume = try await withUnauthorizedRecovery(
            initialSession: session
        ) { session in
            try await backend.resumeThread(id: id, session: session)
        }
        let backendThread = resume.result
        guard backendThread.id == id else {
            throw AgentRuntimeError(
                code: "thread_resume_mismatch",
                message: "The backend resumed thread \(backendThread.id) instead of the requested thread \(id)."
            )
        }
        let resumedAt = Date()
        let maximumSequenceAllocationAttempts = 3
        var attempt = 1

        while true {
            let projection = await makeThreadResumeProjection(
                activation: activation,
                backendThread: backendThread,
                resumedAt: resumedAt
            )
            do {
                try await persistenceCoordinator.apply(projection.operations)

                installActivationState(
                    activation,
                    thread: projection.thread,
                    summary: projection.summary,
                    nextHistorySequence: projection.record.sequenceNumber + 1
                )
                state.historyByThread[id] = [projection.record]
                if let snapshot = makeThreadObservationSnapshot(for: id) {
                    await publishCommittedObservation(
                        AgentRuntimeObservationBatchSnapshot(
                            threadID: id,
                            threadSnapshot: snapshot,
                            isDeletion: false
                        )
                    )
                }
                logger.info(.runtime, "Thread resumed.", metadata: ["thread_id": id])
                return projection.thread
            } catch let error as AgentRuntimeError
                where error.code == "invalid_history_sequence"
                    && attempt < maximumSequenceAllocationAttempts {
                logger.debug(
                    .persistence,
                    "Retrying thread resume after a concurrent sequence allocation.",
                    metadata: [
                        "thread_id": id,
                        "attempt": "\(attempt + 1)",
                    ]
                )
                attempt += 1
                activation = try await stateStore.loadThreadActivationState(
                    id: id,
                    policy: threadActivationPolicy
                )
            }
        }
    }

    func makeThreadResumeProjection(
        activation: AgentThreadActivationState,
        backendThread: AgentThread,
        resumedAt: Date
    ) async -> ThreadResumePersistenceProjection {
        var thread = activation.thread
        if thread.title == nil {
            thread.title = backendThread.title
        }
        if thread.configuration == nil {
            thread.configuration = backendThread.configuration
        }
        if thread.personaStack == nil {
            thread.personaStack = backendThread.personaStack
        }
        if thread.skillIDs.isEmpty {
            thread.skillIDs = backendThread.skillIDs
        }
        if thread.memoryContext == nil {
            thread.memoryContext = backendThread.memoryContext
        }
        thread.status = backendThread.status
        if thread.configuration == nil {
            thread.configuration = await backend.defaultThreadConfiguration
        }
        thread.updatedAt = max(thread.updatedAt, max(backendThread.updatedAt, resumedAt))

        let record = AgentHistoryRecord(
            sequenceNumber: activation.nextHistorySequence,
            createdAt: resumedAt,
            item: .systemEvent(
                AgentSystemEventRecord(
                    type: .threadResumed,
                    threadID: thread.id,
                    occurredAt: resumedAt
                )
            )
        )
        let projectedSummary = StoredRuntimeStateProjectionBuilder().rebuildSummary(
            for: thread,
            history: [record],
            existing: activation.summary
        )
        let summary = AgentThreadSummary(
            threadID: thread.id,
            createdAt: activation.summary.createdAt,
            updatedAt: thread.updatedAt,
            latestItemAt: resumedAt,
            itemCount: (activation.summary.itemCount ?? 0) + 1,
            latestAssistantMessagePreview: projectedSummary.latestAssistantMessagePreview,
            latestStructuredOutputMetadata: projectedSummary.latestStructuredOutputMetadata,
            latestPartialStructuredOutput: projectedSummary.latestPartialStructuredOutput,
            latestToolState: projectedSummary.latestToolState,
            latestTurnStatus: projectedSummary.latestTurnStatus,
            pendingState: projectedSummary.pendingState
        )
        let hydratedContextState = activation.contextState
            ?? AgentThreadContextState(
                threadID: thread.id,
                effectiveMessages: activation.effectiveMessages
            )
        return ThreadResumePersistenceProjection(
            thread: thread,
            summary: summary,
            contextState: hydratedContextState,
            record: record
        )
    }

    /// Releases one thread's hydrated working set without changing durable state.
    public func deactivateThread(id: String) {
        state.threads.removeAll { $0.id == id }
        state.messagesByThread.removeValue(forKey: id)
        state.historyByThread.removeValue(forKey: id)
        state.summariesByThread.removeValue(forKey: id)
        state.contextStateByThread.removeValue(forKey: id)
        state.nextHistorySequenceByThread.removeValue(forKey: id)
        state.partiallyLoadedThreadIDs.remove(id)
        pendingStoreOperations.removeAll { $0.affectedThreadID == id }
        committedObservationSnapshotsByThread.removeValue(forKey: id)
        observationCenter.deactivateThread(id: id, activeThreads: committedActiveThreads())
    }

    // MARK: - Thread Configuration

    func thread(for threadID: String) -> AgentThread? {
        state.threads.first { $0.id == threadID }
    }

    public func personaStack(for threadID: String) throws -> AgentPersonaStack? {
        guard let thread = thread(for: threadID) else {
            throw AgentRuntimeError.threadNotFound(threadID)
        }

        return thread.personaStack
    }

    public func setTitle(
        _ title: String?,
        for threadID: String
    ) async throws {
        guard let index = state.threads.firstIndex(where: { $0.id == threadID }) else {
            throw AgentRuntimeError.threadNotFound(threadID)
        }

        state.threads[index].title = title
        state.threads[index].updatedAt = Date()
        enqueueStoreOperation(.upsertThread(state.threads[index]))
        try await persistState()
        logger.info(
            .runtime,
            "Updated thread title.",
            metadata: [
                "thread_id": threadID,
                "has_title": "\(title?.isEmpty == false)"
            ]
        )
    }

    public func updateThreadConfiguration(
        _ configuration: AgentThreadConfiguration,
        for threadID: String
    ) async throws {
        guard let index = state.threads.firstIndex(where: { $0.id == threadID }) else {
            throw AgentRuntimeError.threadNotFound(threadID)
        }

        state.threads[index].configuration = configuration
        state.threads[index].updatedAt = Date()
        enqueueStoreOperation(.upsertThread(state.threads[index]))
        try await persistState()
        logger.info(
            .runtime,
            "Updated thread configuration.",
            metadata: [
                "thread_id": threadID,
                "model": configuration.model,
                "reasoning_effort": configuration.reasoningEffort.rawValue
            ]
        )
    }

    @discardableResult
    public func updateThreadConfiguration(
        for threadID: String,
        model: String? = nil,
        reasoningEffort: ReasoningEffort? = nil
    ) async throws -> AgentThreadConfiguration {
        guard let thread = thread(for: threadID) else {
            throw AgentRuntimeError.threadNotFound(threadID)
        }

        let existing: AgentThreadConfiguration?
        if let configuration = thread.configuration {
            existing = configuration
        } else {
            existing = await backend.defaultThreadConfiguration
        }
        guard existing != nil || model != nil || reasoningEffort != nil else {
            throw AgentRuntimeError(
                code: "thread_configuration_unavailable",
                message: "No thread configuration is available to update."
            )
        }

        let resolved = AgentThreadConfiguration(
            model: model ?? existing?.model ?? "",
            reasoningEffort: reasoningEffort ?? existing?.reasoningEffort ?? .medium
        )
        try await updateThreadConfiguration(resolved, for: threadID)
        return resolved
    }

    public func setPersonaStack(
        _ personaStack: AgentPersonaStack?,
        for threadID: String
    ) async throws {
        guard let index = state.threads.firstIndex(where: { $0.id == threadID }) else {
            throw AgentRuntimeError.threadNotFound(threadID)
        }

        state.threads[index].personaStack = personaStack
        state.threads[index].updatedAt = Date()
        enqueueStoreOperation(.upsertThread(state.threads[index]))
        try await persistState()
    }

    @discardableResult
    public func setPersonaStack(
        from source: AgentDefinitionSource,
        for threadID: String,
        defaultLayerName: String = "dynamic_persona"
    ) async throws -> AgentPersonaStack {
        let personaStack = try await definitionSourceLoader.loadPersonaStack(
            from: source,
            defaultLayerName: defaultLayerName
        )
        try await setPersonaStack(personaStack, for: threadID)
        return personaStack
    }

    public func setMemoryContext(
        _ memoryContext: AgentMemoryContext?,
        for threadID: String
    ) async throws {
        guard let index = state.threads.firstIndex(where: { $0.id == threadID }) else {
            throw AgentRuntimeError.threadNotFound(threadID)
        }

        state.threads[index].memoryContext = memoryContext
        state.threads[index].updatedAt = Date()
        enqueueStoreOperation(.upsertThread(state.threads[index]))
        try await persistState()
    }

    // MARK: - State Mutation

    func upsertThread(
        _ thread: AgentThread,
        persist: Bool = true
    ) async throws {
        if let index = state.threads.firstIndex(where: { $0.id == thread.id }) {
            var mergedThread = thread
            if mergedThread.title == nil {
                mergedThread.title = state.threads[index].title
            }
            if mergedThread.configuration == nil {
                mergedThread.configuration = state.threads[index].configuration
            }
            if mergedThread.personaStack == nil {
                mergedThread.personaStack = state.threads[index].personaStack
            }
            if mergedThread.skillIDs.isEmpty {
                mergedThread.skillIDs = state.threads[index].skillIDs
            }
            if mergedThread.memoryContext == nil {
                mergedThread.memoryContext = state.threads[index].memoryContext
            }
            state.threads[index] = mergedThread
            enqueueStoreOperation(.upsertThread(state.threads[index]))
        } else {
            state.threads.append(thread)
            enqueueStoreOperation(.upsertThread(thread))
        }
        if state.summariesByThread[thread.id] == nil {
            let summary = state.threadSummaryFallback(for: thread)
            state.summariesByThread[thread.id] = summary
            enqueueStoreOperation(.upsertSummary(threadID: thread.id, summary: summary))
        }
        if persist {
            try await persistState()
        }
    }

    func setThreadStatus(
        _ status: AgentThreadStatus,
        for threadID: String
    ) async throws {
        guard let index = state.threads.firstIndex(where: { $0.id == threadID }) else {
            throw AgentRuntimeError.threadNotFound(threadID)
        }

        let previousStatus = state.threads[index].status
        state.threads[index].status = status
        state.threads[index].updatedAt = Date()
        enqueueStoreOperation(.upsertThread(state.threads[index]))
        if previousStatus != status {
            appendHistoryItem(
                .systemEvent(
                    AgentSystemEventRecord(
                        type: .threadStatusChanged,
                        threadID: threadID,
                        status: status,
                        occurredAt: state.threads[index].updatedAt
                    )
                ),
                threadID: threadID,
                createdAt: state.threads[index].updatedAt
            )
        }
        try await persistState()
        logger.debug(
            .runtime,
            "Thread status changed.",
            metadata: [
                "thread_id": threadID,
                "status": status.rawValue
            ]
        )
    }

    func appendMessage(_ message: AgentMessage) async throws {
        logger.debug(
            .runtime,
            "Appending message to thread.",
            metadata: [
                "thread_id": message.threadID,
                "role": message.role.rawValue,
                "text_length": "\(message.text.count)",
                "image_count": "\(message.images.count)"
            ]
        )
        state.messagesByThread[message.threadID, default: []].append(message)
        appendEffectiveMessage(message)
        if lazyThreadActivationEnabled {
            state.messagesByThread[message.threadID] = AgentThreadContextWindow.boundedMessages(
                state.messagesByThread[message.threadID] ?? [],
                policy: threadActivationPolicy,
                requireClosedTurns: false
            )
        }
        appendHistoryItem(
            .message(message),
            threadID: message.threadID,
            createdAt: message.createdAt
        )

        if let index = state.threads.firstIndex(where: { $0.id == message.threadID }) {
            state.threads[index].updatedAt = message.createdAt
            if state.threads[index].title == nil, message.role == .user {
                if !message.text.isEmpty {
                    state.threads[index].title = String(message.text.prefix(48))
                } else if !message.images.isEmpty {
                    state.threads[index].title = message.images.count == 1
                        ? "Image message"
                        : "Image message (\(message.images.count))"
                }
            }
            enqueueStoreOperation(.upsertThread(state.threads[index]))
        }

        try await persistState()
    }
}
