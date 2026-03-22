import Foundation

public actor AgentRuntime {
    public struct ToolRegistration: Sendable {
        public let definition: ToolDefinition
        public let executor: AnyToolExecutor

        public init(
            definition: ToolDefinition,
            executor: AnyToolExecutor
        ) {
            self.definition = definition
            self.executor = executor
        }
    }

    public struct Configuration: Sendable {
        public let authProvider: any ChatGPTAuthProviding
        public let secureStore: any SessionSecureStoring
        public let backend: any AgentBackend
        public let approvalPresenter: any ApprovalPresenting
        public let stateStore: any RuntimeStateStoring
        public let memory: AgentMemoryConfiguration?
        public let baseInstructions: String?
        public let tools: [ToolRegistration]
        public let skills: [AgentSkill]
        public let definitionSourceLoader: AgentDefinitionSourceLoader

        public init(
            authProvider: any ChatGPTAuthProviding,
            secureStore: any SessionSecureStoring,
            backend: any AgentBackend,
            approvalPresenter: any ApprovalPresenting,
            stateStore: any RuntimeStateStoring,
            memory: AgentMemoryConfiguration? = nil,
            baseInstructions: String? = nil,
            tools: [ToolRegistration] = [],
            skills: [AgentSkill] = [],
            definitionSourceLoader: AgentDefinitionSourceLoader = AgentDefinitionSourceLoader()
        ) {
            self.authProvider = authProvider
            self.secureStore = secureStore
            self.backend = backend
            self.approvalPresenter = approvalPresenter
            self.stateStore = stateStore
            self.memory = memory
            self.baseInstructions = baseInstructions
            self.tools = tools
            self.skills = skills
            self.definitionSourceLoader = definitionSourceLoader
        }
    }

    private let backend: any AgentBackend
    private let stateStore: any RuntimeStateStoring
    private let sessionManager: ChatGPTSessionManager
    private let toolRegistry: ToolRegistry
    private let approvalCoordinator: ApprovalCoordinator
    private let memoryConfiguration: AgentMemoryConfiguration?
    private let baseInstructions: String?
    private let definitionSourceLoader: AgentDefinitionSourceLoader
    private var skillsByID: [String: AgentSkill]

    private var state: StoredRuntimeState = .empty

    private struct ResolvedTurnSkills {
        let threadSkills: [AgentSkill]
        let turnSkills: [AgentSkill]
        let compiledToolPolicy: CompiledSkillToolPolicy
    }

    private struct CompiledSkillToolPolicy {
        let allowedToolNames: Set<String>?
        let requiredToolNames: Set<String>
        let toolSequence: [String]?
        let maxToolCalls: Int?

        var hasConstraints: Bool {
            allowedToolNames != nil ||
                !requiredToolNames.isEmpty ||
                (toolSequence?.isEmpty == false) ||
                maxToolCalls != nil
        }
    }

    private final class TurnSkillPolicyTracker: @unchecked Sendable {
        private let policy: CompiledSkillToolPolicy
        private var toolCallsCount = 0
        private var usedToolNames: Set<String> = []
        private var nextSequenceIndex = 0

        init(policy: CompiledSkillToolPolicy) {
            self.policy = policy
        }

        func validate(toolName: String) -> AgentRuntimeError? {
            if let maxToolCalls = policy.maxToolCalls,
               toolCallsCount >= maxToolCalls {
                return AgentRuntimeError.skillToolCallLimitExceeded(maxToolCalls)
            }

            if let allowedToolNames = policy.allowedToolNames,
               !allowedToolNames.contains(toolName) {
                return AgentRuntimeError.skillToolNotAllowed(toolName)
            }

            if let toolSequence = policy.toolSequence,
               nextSequenceIndex < toolSequence.count {
                let expectedToolName = toolSequence[nextSequenceIndex]
                if toolName != expectedToolName {
                    return AgentRuntimeError.skillToolSequenceViolation(
                        expected: expectedToolName,
                        actual: toolName
                    )
                }
            }

            return nil
        }

        func recordAccepted(toolName: String) {
            toolCallsCount += 1
            usedToolNames.insert(toolName)

            if let toolSequence = policy.toolSequence,
               nextSequenceIndex < toolSequence.count,
               toolSequence[nextSequenceIndex] == toolName {
                nextSequenceIndex += 1
            }
        }

        func completionError() -> AgentRuntimeError? {
            var missingTools = policy.requiredToolNames.subtracting(usedToolNames)

            if let toolSequence = policy.toolSequence,
               nextSequenceIndex < toolSequence.count {
                let remainingSequenceTools = toolSequence[nextSequenceIndex...]
                missingTools.formUnion(remainingSequenceTools)
            }

            guard !missingTools.isEmpty else {
                return nil
            }

            return AgentRuntimeError.skillRequiredToolsMissing(Array(missingTools).sorted())
        }
    }

    public init(configuration: Configuration) throws {
        self.backend = configuration.backend
        self.stateStore = configuration.stateStore
        self.sessionManager = ChatGPTSessionManager(
            authProvider: configuration.authProvider,
            secureStore: configuration.secureStore
        )
        self.toolRegistry = try ToolRegistry(initialTools: configuration.tools)
        self.approvalCoordinator = ApprovalCoordinator(
            presenter: configuration.approvalPresenter
        )
        self.memoryConfiguration = configuration.memory
        self.baseInstructions = configuration.baseInstructions ?? configuration.backend.baseInstructions
        self.definitionSourceLoader = configuration.definitionSourceLoader
        self.skillsByID = try Self.validatedSkills(from: configuration.skills)
    }

    @discardableResult
    public func restore() async throws -> StoredRuntimeState {
        _ = try await sessionManager.restore()
        state = try await stateStore.loadState()
        return state
    }

    @discardableResult
    public func signIn() async throws -> ChatGPTSession {
        try await sessionManager.signIn()
    }

    public func currentSession() async -> ChatGPTSession? {
        await sessionManager.currentSession()
    }

    public func signOut() async throws {
        try await sessionManager.signOut()
    }

    public func threads() -> [AgentThread] {
        state.threads.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func messages(for threadID: String) -> [AgentMessage] {
        state.messagesByThread[threadID] ?? []
    }

    public func registerTool(
        _ definition: ToolDefinition,
        executor: AnyToolExecutor
    ) async throws {
        try await toolRegistry.register(definition, executor: executor)
    }

    public func replaceTool(
        _ definition: ToolDefinition,
        executor: AnyToolExecutor
    ) async throws {
        try await toolRegistry.replace(definition, executor: executor)
    }

    public func skills() -> [AgentSkill] {
        skillsByID.values.sorted { $0.id < $1.id }
    }

    public func skill(for skillID: String) -> AgentSkill? {
        skillsByID[skillID]
    }

    public func registerSkill(_ skill: AgentSkill) throws {
        guard AgentSkill.isValidID(skill.id) else {
            throw AgentRuntimeError.invalidSkillID(skill.id)
        }
        try Self.validateSkillExecutionPolicy(skill)
        guard skillsByID[skill.id] == nil else {
            throw AgentRuntimeError.duplicateSkill(skill.id)
        }

        skillsByID[skill.id] = skill
    }

    public func replaceSkill(_ skill: AgentSkill) throws {
        guard AgentSkill.isValidID(skill.id) else {
            throw AgentRuntimeError.invalidSkillID(skill.id)
        }
        try Self.validateSkillExecutionPolicy(skill)

        skillsByID[skill.id] = skill
    }

    @discardableResult
    public func registerSkill(
        from source: AgentDefinitionSource,
        id: String? = nil,
        name: String? = nil
    ) async throws -> AgentSkill {
        let skill = try await definitionSourceLoader.loadSkill(
            from: source,
            id: id,
            name: name
        )
        try registerSkill(skill)
        return skill
    }

    @discardableResult
    public func replaceSkill(
        from source: AgentDefinitionSource,
        id: String? = nil,
        name: String? = nil
    ) async throws -> AgentSkill {
        let skill = try await definitionSourceLoader.loadSkill(
            from: source,
            id: id,
            name: name
        )
        try replaceSkill(skill)
        return skill
    }

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
        try await upsertThread(thread)
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
        try await upsertThread(thread)
        return thread
    }

    public func sendMessage(
        _ request: UserMessageRequest,
        in threadID: String
    ) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        guard request.hasContent else {
            throw AgentRuntimeError.invalidMessageContent()
        }

        guard let thread = thread(for: threadID) else {
            throw AgentRuntimeError.threadNotFound(threadID)
        }

        let session = try await sessionManager.requireSession()
        let userMessage = AgentMessage(
            threadID: threadID,
            role: .user,
            text: request.text,
            images: request.images
        )
        let priorMessages = state.messagesByThread[threadID] ?? []
        let resolvedTurnSkills = try resolveTurnSkills(
            thread: thread,
            message: request
        )
        let resolvedInstructions = await resolveInstructions(
            thread: thread,
            message: request,
            resolvedTurnSkills: resolvedTurnSkills
        )

        try await appendMessage(userMessage)
        try await setThreadStatus(.streaming, for: threadID)

        let tools = await toolRegistry.allDefinitions()
        let turnStart = try await beginTurnWithUnauthorizedRecovery(
            thread: thread,
            history: priorMessages,
            message: request,
            instructions: resolvedInstructions,
            tools: tools,
            session: session
        )
        let turnStream = turnStart.turnStream
        let turnSession = turnStart.session

        return AsyncThrowingStream { continuation in
            continuation.yield(.messageCommitted(userMessage))
            continuation.yield(.threadStatusChanged(threadID: threadID, status: .streaming))

            Task {
                await self.consumeTurnStream(
                    turnStream,
                    for: threadID,
                    session: turnSession,
                    resolvedTurnSkills: resolvedTurnSkills,
                    continuation: continuation
                )
            }
        }
    }

    private func beginTurnWithUnauthorizedRecovery(
        thread: AgentThread,
        history: [AgentMessage],
        message: UserMessageRequest,
        instructions: String,
        tools: [ToolDefinition],
        session: ChatGPTSession
    ) async throws -> (
        turnStream: any AgentTurnStreaming,
        session: ChatGPTSession
    ) {
        let beginTurn = try await withUnauthorizedRecovery(
            initialSession: session
        ) { session in
            try await backend.beginTurn(
                thread: thread,
                history: history,
                message: message,
                instructions: instructions,
                tools: tools,
                session: session
            )
        }
        return (beginTurn.result, beginTurn.session)
    }

    public func resolvedInstructionsPreview(
        for threadID: String,
        request: UserMessageRequest
    ) async throws -> String {
        guard let thread = thread(for: threadID) else {
            throw AgentRuntimeError.threadNotFound(threadID)
        }

        let resolvedTurnSkills = try resolveTurnSkills(
            thread: thread,
            message: request
        )

        return await resolveInstructions(
            thread: thread,
            message: request,
            resolvedTurnSkills: resolvedTurnSkills
        )
    }

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

    private func consumeTurnStream(
        _ turnStream: any AgentTurnStreaming,
        for threadID: String,
        session: ChatGPTSession,
        resolvedTurnSkills: ResolvedTurnSkills,
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    ) async {
        let policyTracker: TurnSkillPolicyTracker? = if resolvedTurnSkills.compiledToolPolicy.hasConstraints {
            TurnSkillPolicyTracker(policy: resolvedTurnSkills.compiledToolPolicy)
        } else {
            nil
        }

        do {
            for try await backendEvent in turnStream.events {
                switch backendEvent {
                case let .turnStarted(turn):
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
                    continuation.yield(.messageCommitted(message))

                case let .toolCallRequested(invocation):
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
                        try await setThreadStatus(.failed, for: threadID)
                        continuation.yield(.threadStatusChanged(threadID: threadID, status: .failed))
                        continuation.yield(.turnFailed(completionError))
                        continuation.finish(throwing: completionError)
                        return
                    }

                    try await setThreadStatus(.idle, for: threadID)
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
            try? await setThreadStatus(.failed, for: threadID)
            continuation.yield(.threadStatusChanged(threadID: threadID, status: .failed))
            continuation.yield(.turnFailed(runtimeError))
            continuation.finish(throwing: error)
        }
    }

    private func resolveToolInvocation(
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

            try await setThreadStatus(.waitingForApproval, for: invocation.threadID)
            continuation.yield(
                .threadStatusChanged(
                    threadID: invocation.threadID,
                    status: .waitingForApproval
                )
            )
            continuation.yield(.approvalRequested(approval))

            let decision = try await approvalCoordinator.requestApproval(approval)
            continuation.yield(
                .approvalResolved(
                    ApprovalResolution(
                        requestID: approval.id,
                        threadID: approval.threadID,
                        turnID: approval.turnID,
                        decision: decision
                    )
                )
            )

            guard decision == .approved else {
                return .denied(invocation: invocation)
            }
        }

        try await setThreadStatus(.waitingForToolResult, for: invocation.threadID)
        continuation.yield(
            .threadStatusChanged(
                threadID: invocation.threadID,
                status: .waitingForToolResult
            )
        )

        return await toolRegistry.execute(invocation, session: session)
    }

    private func thread(for threadID: String) -> AgentThread? {
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

    public func skillIDs(for threadID: String) throws -> [String] {
        guard let thread = thread(for: threadID) else {
            throw AgentRuntimeError.threadNotFound(threadID)
        }

        return thread.skillIDs
    }

    public func memoryContext(for threadID: String) throws -> AgentMemoryContext? {
        guard let thread = thread(for: threadID) else {
            throw AgentRuntimeError.threadNotFound(threadID)
        }

        return thread.memoryContext
    }

    public func setSkillIDs(
        _ skillIDs: [String],
        for threadID: String
    ) async throws {
        guard let index = state.threads.firstIndex(where: { $0.id == threadID }) else {
            throw AgentRuntimeError.threadNotFound(threadID)
        }
        try assertSkillsExist(skillIDs)

        state.threads[index].skillIDs = skillIDs
        state.threads[index].updatedAt = Date()
        try await persistState()
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
        try await persistState()
    }

    private func upsertThread(_ thread: AgentThread) async throws {
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
        } else {
            state.threads.append(thread)
        }
        try await persistState()
    }

    private func setThreadStatus(
        _ status: AgentThreadStatus,
        for threadID: String
    ) async throws {
        guard let index = state.threads.firstIndex(where: { $0.id == threadID }) else {
            throw AgentRuntimeError.threadNotFound(threadID)
        }

        state.threads[index].status = status
        state.threads[index].updatedAt = Date()
        try await persistState()
    }

    private func appendMessage(_ message: AgentMessage) async throws {
        state.messagesByThread[message.threadID, default: []].append(message)

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
        }

        try await persistState()
    }

    private func persistState() async throws {
        try await stateStore.saveState(state)
    }

    private func resolveInstructions(
        thread: AgentThread,
        message: UserMessageRequest,
        resolvedTurnSkills: ResolvedTurnSkills
    ) async -> String {
        let compiled = AgentInstructionCompiler.compile(
            baseInstructions: baseInstructions,
            threadPersonaStack: thread.personaStack,
            threadSkills: resolvedTurnSkills.threadSkills,
            turnPersonaOverride: message.personaOverride,
            turnSkills: resolvedTurnSkills.turnSkills
        )

        guard let queryResult = await resolvedMemoryQuery(
            thread: thread,
            message: message
        ),
        let memoryConfiguration
        else {
            return compiled
        }

        let budget = resolvedMemoryBudget(
            thread: thread,
            message: message,
            fallback: memoryConfiguration.defaultReadBudget
        )
        let renderedMemory = memoryConfiguration.promptRenderer.render(
            result: queryResult,
            budget: budget
        )
        guard !renderedMemory.isEmpty else {
            return compiled
        }

        if compiled.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return renderedMemory
        }

        return """
        \(compiled)

        \(renderedMemory)
        """
    }

    private static func isUnauthorizedError(_ error: Error) -> Bool {
        (error as? AgentRuntimeError)?.code == AgentRuntimeError.unauthorized().code
    }

    private func withUnauthorizedRecovery<Result: Sendable>(
        initialSession: ChatGPTSession,
        operation: (ChatGPTSession) async throws -> Result
    ) async throws -> (
        result: Result,
        session: ChatGPTSession
    ) {
        do {
            return (try await operation(initialSession), initialSession)
        } catch {
            guard Self.isUnauthorizedError(error) else {
                throw error
            }

            let recoveredSession = try await sessionManager.recoverUnauthorizedSession(
                previousAccessToken: initialSession.accessToken
            )
            return (try await operation(recoveredSession), recoveredSession)
        }
    }

    private func resolveTurnSkills(
        thread: AgentThread,
        message: UserMessageRequest
    ) throws -> ResolvedTurnSkills {
        if let skillOverrideIDs = message.skillOverrideIDs {
            try assertSkillsExist(skillOverrideIDs)
        }

        let threadSkills = resolveSkills(for: thread.skillIDs)
        let turnSkills = resolveSkills(for: message.skillOverrideIDs ?? [])
        let allSkills = threadSkills + turnSkills

        return ResolvedTurnSkills(
            threadSkills: threadSkills,
            turnSkills: turnSkills,
            compiledToolPolicy: compileToolPolicy(from: allSkills)
        )
    }

    private func resolvedMemoryQuery(
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

    private func resolvedMemoryQuery(
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

    private func resolvedMemoryBudget(
        thread: AgentThread,
        message: UserMessageRequest,
        fallback: MemoryReadBudget
    ) -> MemoryReadBudget {
        message.memorySelection?.readBudget
            ?? thread.memoryContext?.readBudget
            ?? fallback
    }

    private func uniqueScopes(_ scopes: [MemoryScope]) -> [MemoryScope] {
        var seen: Set<MemoryScope> = []
        return scopes.filter { seen.insert($0).inserted }
    }

    private func resolvedValues(
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

    private func compileToolPolicy(from skills: [AgentSkill]) -> CompiledSkillToolPolicy {
        var allowedToolNames: Set<String>?
        var requiredToolNames: Set<String> = []
        var toolSequence: [String]?
        var maxToolCalls: Int?

        for skill in skills {
            guard let executionPolicy = skill.executionPolicy else {
                continue
            }

            if let allowed = executionPolicy.allowedToolNames,
               !allowed.isEmpty {
                let allowedSet = Set(allowed)
                if let existingAllowed = allowedToolNames {
                    allowedToolNames = existingAllowed.intersection(allowedSet)
                } else {
                    allowedToolNames = allowedSet
                }
            }

            if !executionPolicy.requiredToolNames.isEmpty {
                requiredToolNames.formUnion(executionPolicy.requiredToolNames)
            }

            if let sequence = executionPolicy.toolSequence,
               !sequence.isEmpty {
                toolSequence = sequence
            }

            if let maxCalls = executionPolicy.maxToolCalls {
                if let existingMaxCalls = maxToolCalls {
                    maxToolCalls = min(existingMaxCalls, maxCalls)
                } else {
                    maxToolCalls = maxCalls
                }
            }
        }

        return CompiledSkillToolPolicy(
            allowedToolNames: allowedToolNames,
            requiredToolNames: requiredToolNames,
            toolSequence: toolSequence,
            maxToolCalls: maxToolCalls
        )
    }

    private func resolveSkills(for skillIDs: [String]) -> [AgentSkill] {
        skillIDs.compactMap { skillsByID[$0] }
    }

    private func assertSkillsExist(_ skillIDs: [String]) throws {
        let missing = Array(Set(skillIDs.filter { skillsByID[$0] == nil })).sorted()
        guard missing.isEmpty else {
            throw AgentRuntimeError.skillsNotFound(missing)
        }
    }

    private static func validatedSkills(from skills: [AgentSkill]) throws -> [String: AgentSkill] {
        var dictionary: [String: AgentSkill] = [:]
        for skill in skills {
            guard AgentSkill.isValidID(skill.id) else {
                throw AgentRuntimeError.invalidSkillID(skill.id)
            }
            try validateSkillExecutionPolicy(skill)
            guard dictionary[skill.id] == nil else {
                throw AgentRuntimeError.duplicateSkill(skill.id)
            }
            dictionary[skill.id] = skill
        }
        return dictionary
    }

    private static func validateSkillExecutionPolicy(_ skill: AgentSkill) throws {
        guard let executionPolicy = skill.executionPolicy else {
            return
        }

        if let maxToolCalls = executionPolicy.maxToolCalls,
           maxToolCalls < 0 {
            throw AgentRuntimeError.invalidSkillMaxToolCalls(skillID: skill.id)
        }

        let policyToolNames: [String] =
            (executionPolicy.allowedToolNames ?? []) +
            executionPolicy.requiredToolNames +
            (executionPolicy.toolSequence ?? [])

        for toolName in policyToolNames {
            guard ToolDefinition.isValidName(toolName) else {
                throw AgentRuntimeError.invalidSkillToolName(
                    skillID: skill.id,
                    toolName: toolName
                )
            }
        }
    }
}
