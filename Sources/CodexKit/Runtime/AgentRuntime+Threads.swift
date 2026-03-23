import Foundation

extension AgentRuntime {
    // MARK: - Threads

    @discardableResult
    public func createThread(
        title: String? = nil,
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
        let creation = try await withUnauthorizedRecovery(
            initialSession: session
        ) { session in
            try await backend.createThread(session: session)
        }
        var thread = creation.result
        if let title {
            thread.title = title
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
        return thread
    }

    @discardableResult
    public func resumeThread(id: String) async throws -> AgentThread {
        let session = try await sessionManager.requireSession()
        let resume = try await withUnauthorizedRecovery(
            initialSession: session
        ) { session in
            try await backend.resumeThread(id: id, session: session)
        }
        let thread = resume.result
        try await upsertThread(thread, persist: false)
        appendHistoryItem(
            .systemEvent(
                AgentSystemEventRecord(
                    type: .threadResumed,
                    threadID: thread.id,
                    occurredAt: Date()
                )
            ),
            threadID: thread.id,
            createdAt: Date()
        )
        updateThreadTimestamp(Date(), for: thread.id)
        try await persistState()
        return thread
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
    }

    func appendMessage(_ message: AgentMessage) async throws {
        state.messagesByThread[message.threadID, default: []].append(message)
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
