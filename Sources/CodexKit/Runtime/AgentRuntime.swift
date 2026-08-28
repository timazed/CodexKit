import Combine
import Foundation

public actor AgentRuntime {
    // MARK: - Configuration

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
        public let authProvider: ChatGPTAuthProvider
        public let secureStore: KeychainSessionSecureStore
        public let backend: any AgentBackend
        public let approvalPresenter: any ApprovalPresenting
        public let stateStore: any RuntimeStateStoring
        public let logging: AgentLoggingConfiguration
        public let memory: AgentMemoryConfiguration?
        public let baseInstructions: String?
        public let tools: [ToolRegistration]
        public let skills: [AgentSkill]
        public let definitionSourceLoader: AgentDefinitionSourceLoader
        public let contextCompaction: AgentContextCompactionConfiguration
        public let threadActivationPolicy: AgentThreadActivationPolicy
        public let backgroundActivityProvider: any AgentBackgroundActivityProviding

        public init(
            authProvider: ChatGPTAuthProvider,
            secureStore: KeychainSessionSecureStore,
            backend: any AgentBackend,
            approvalPresenter: any ApprovalPresenting,
            stateStore: any RuntimeStateStoring,
            logging: AgentLoggingConfiguration = .disabled,
            memory: AgentMemoryConfiguration? = nil,
            baseInstructions: String? = nil,
            tools: [ToolRegistration] = [],
            skills: [AgentSkill] = [],
            definitionSourceLoader: AgentDefinitionSourceLoader = AgentDefinitionSourceLoader(),
            contextCompaction: AgentContextCompactionConfiguration = AgentContextCompactionConfiguration(),
            threadActivationPolicy: AgentThreadActivationPolicy = AgentThreadActivationPolicy(),
            backgroundActivityProvider: any AgentBackgroundActivityProviding = NoOpAgentBackgroundActivityProvider()
        ) {
            self.authProvider = authProvider
            self.secureStore = secureStore
            self.backend = backend
            self.approvalPresenter = approvalPresenter
            self.stateStore = stateStore
            self.logging = logging
            self.memory = memory
            self.baseInstructions = baseInstructions
            self.tools = tools
            self.skills = skills
            self.definitionSourceLoader = definitionSourceLoader
            self.contextCompaction = contextCompaction
            self.threadActivationPolicy = threadActivationPolicy
            self.backgroundActivityProvider = backgroundActivityProvider
        }
    }

    let backend: any AgentBackend
    let stateStore: any RuntimeStateStoring
    let sessionManager: ChatGPTSessionManager
    let logger: AgentLogger
    let toolRegistry: ToolRegistry
    let approvalCoordinator: ApprovalCoordinator
    let memoryConfiguration: AgentMemoryConfiguration?
    let configuredBaseInstructions: String?
    let definitionSourceLoader: AgentDefinitionSourceLoader
    let contextCompactionConfiguration: AgentContextCompactionConfiguration
    let observationCenter: AgentRuntimeObservationCenter
    let persistenceCoordinator: AgentRuntimePersistenceCoordinator
    let threadActivationPolicy: AgentThreadActivationPolicy
    let backgroundActivityProvider: any AgentBackgroundActivityProviding
    var skillsByID: [String: AgentSkill]

    var state: StoredRuntimeState = .empty
    var pendingStoreOperations: [AgentRuntimePendingStoreOperation] = []
    var nextStoreOperationGeneration: UInt64 = 0
    var nextPersistenceTaskID: UInt64 = 0
    var activePersistenceTask: AgentRuntimeActivePersistenceTask?
    var committedObservationSnapshotsByThread: [String: AgentRuntimeThreadObservationSnapshot] = [:]
    var lazyThreadActivationEnabled = false
    var resumingThreadIDs: Set<String> = []
    var resumeWaitersByThread: [String: [CheckedContinuation<Void, Never>]] = [:]

    struct ResolvedTurnSkills {
        let threadSkills: [AgentSkill]
        let turnSkills: [AgentSkill]
        let compiledToolPolicy: CompiledSkillToolPolicy
    }

    struct CompiledSkillToolPolicy {
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

    final class TurnSkillPolicyTracker {
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

    // MARK: - Lifecycle

    public init(configuration: Configuration) throws {
        self.backend = configuration.backend
        self.stateStore = configuration.stateStore
        self.logger = AgentLogger(configuration: configuration.logging)
        self.sessionManager = ChatGPTSessionManager(
            authProvider: configuration.authProvider,
            secureStore: configuration.secureStore,
            logging: configuration.logging
        )
        self.toolRegistry = try ToolRegistry(initialTools: configuration.tools)
        self.approvalCoordinator = ApprovalCoordinator(
            presenter: configuration.approvalPresenter
        )
        self.memoryConfiguration = configuration.memory
        self.configuredBaseInstructions = configuration.baseInstructions
        self.definitionSourceLoader = configuration.definitionSourceLoader
        self.contextCompactionConfiguration = configuration.contextCompaction
        self.observationCenter = AgentRuntimeObservationCenter()
        self.persistenceCoordinator = AgentRuntimePersistenceCoordinator(store: configuration.stateStore)
        self.threadActivationPolicy = configuration.threadActivationPolicy
        self.backgroundActivityProvider = configuration.backgroundActivityProvider
        self.skillsByID = try Self.validatedSkills(from: configuration.skills)
    }

    public var observations: AgentRuntimeObservationPublisher<AgentRuntimeObservation> {
        let observationCenter = observationCenter
        return AgentRuntimeObservationPublisher {
            observationCenter.publisher
        }
    }

    @discardableResult
    public func restore() async throws -> StoredRuntimeState {
        logger.info(.runtime, "Restoring runtime state.")
        _ = try await sessionManager.restore()
        let metadata = try await stateStore.prepare()
        lazyThreadActivationEnabled = metadata.capabilities.supportsLazyThreadActivation
        state = lazyThreadActivationEnabled
            ? .empty
            : try await stateStore.loadState()
        pendingStoreOperations.removeAll()
        synchronizeCommittedObservationSnapshotsFromState()
        await publishAllObservations()
        logger.info(
            .runtime,
            "Runtime restore completed.",
            metadata: [
                "threads": "\(state.threads.count)",
                "history_threads": "\(state.historyByThread.count)"
            ]
        )
        return state
    }

    @discardableResult
    public func signIn() async throws -> ChatGPTSession {
        logger.info(.auth, "Starting interactive sign-in.")
        let session = try await sessionManager.signIn()
        logger.info(
            .auth,
            "Interactive sign-in completed.",
            metadata: [
                "account_id": session.account.id,
                "plan": session.account.plan.rawValue
            ]
        )
        return session
    }

    @discardableResult
    public func useSession(_ session: ChatGPTSession) async throws -> ChatGPTSession {
        logger.info(.auth, "Loading supplied ChatGPT session.")
        return try await sessionManager.useSession(session)
    }

    public func currentSession() async -> ChatGPTSession? {
        await sessionManager.currentSession()
    }

    public func signOut() async throws {
        logger.info(.auth, "Signing out current session.")
        try await sessionManager.signOut()
    }

    // MARK: - Read State

    /// Threads currently hydrated in this runtime's bounded working set.
    public func activeThreads() -> [AgentThread] {
        state.threads.sorted { $0.updatedAt > $1.updatedAt }
    }

    @available(*, deprecated, renamed: "activeThreads()")
    public func threads() -> [AgentThread] {
        activeThreads()
    }

    public func activeThreadCount() -> Int {
        state.threads.count
    }

    public func messages(for threadID: String) -> [AgentMessage] {
        state.messagesByThread[threadID] ?? []
    }

    // MARK: - Tools

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

    // MARK: - Instruction Resolution

    func installActivationState(
        _ activation: AgentThreadActivationState,
        thread: AgentThread? = nil,
        summary: AgentThreadSummary? = nil,
        nextHistorySequence: Int? = nil
    ) {
        let activatedThread = thread ?? activation.thread
        state.threads.removeAll { $0.id == activatedThread.id }
        state.threads.append(activatedThread)
        state.messagesByThread[activatedThread.id] = activation.effectiveMessages
        state.historyByThread[activatedThread.id] = []
        state.summariesByThread[activatedThread.id] = summary ?? activation.summary
        state.contextStateByThread[activatedThread.id] = activation.contextState
            ?? AgentThreadContextState(
                threadID: activatedThread.id,
                effectiveMessages: activation.effectiveMessages
            )
        state.nextHistorySequenceByThread[activatedThread.id] = nextHistorySequence
            ?? activation.nextHistorySequence
        state.partiallyLoadedThreadIDs.insert(activatedThread.id)
    }

    func acquireThreadResume(_ threadID: String) async {
        guard resumingThreadIDs.contains(threadID) else {
            resumingThreadIDs.insert(threadID)
            return
        }
        await withCheckedContinuation { continuation in
            resumeWaitersByThread[threadID, default: []].append(continuation)
        }
    }

    func releaseThreadResume(_ threadID: String) {
        if var waiters = resumeWaitersByThread[threadID], !waiters.isEmpty {
            let next = waiters.removeFirst()
            resumeWaitersByThread[threadID] = waiters.isEmpty ? nil : waiters
            next.resume()
        } else {
            resumingThreadIDs.remove(threadID)
        }
    }

    func publishAllObservations() async {
        observationCenter.send(.threadsChanged(committedActiveThreads()))
        for snapshot in committedObservationSnapshotsByThread.values.sorted(by: {
            $0.thread.updatedAt > $1.thread.updatedAt
        }) {
            await publishThreadObservations(snapshot)
        }
    }

    func synchronizeCommittedObservationSnapshotsFromState() {
        committedObservationSnapshotsByThread = Dictionary(
            uniqueKeysWithValues: state.threads.compactMap { thread in
                makeThreadObservationSnapshot(for: thread.id).map { (thread.id, $0) }
            }
        )
    }

    func makeThreadObservationSnapshot(
        for threadID: String
    ) -> AgentRuntimeThreadObservationSnapshot? {
        guard let thread = thread(for: threadID) else {
            return nil
        }
        return AgentRuntimeThreadObservationSnapshot(
            thread: thread,
            messages: state.messagesByThread[threadID] ?? [],
            summary: state.summariesByThread[threadID]
                ?? state.threadSummaryFallback(for: thread),
            contextState: state.contextStateByThread[threadID],
            effectiveMessages: effectiveHistory(for: threadID)
        )
    }

    func committedActiveThreads() -> [AgentThread] {
        committedObservationSnapshotsByThread.values
            .map(\.thread)
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func publishCommittedObservation(
        _ batch: AgentRuntimeObservationBatchSnapshot
    ) async {
        if batch.isDeletion {
            committedObservationSnapshotsByThread.removeValue(forKey: batch.threadID)
            observationCenter.send(.threadsChanged(committedActiveThreads()))
            observationCenter.send(.threadDeleted(threadID: batch.threadID))
            return
        }
        guard let snapshot = batch.threadSnapshot else { return }

        committedObservationSnapshotsByThread[batch.threadID] = snapshot
        observationCenter.send(.threadsChanged(committedActiveThreads()))
        await publishThreadObservations(snapshot)
    }

    func publishThreadObservations(
        _ snapshot: AgentRuntimeThreadObservationSnapshot
    ) async {
        let threadID = snapshot.thread.id
        observationCenter.send(.threadChanged(snapshot.thread))
        observationCenter.send(
            .messagesChanged(
                threadID: threadID,
                messages: snapshot.messages
            )
        )
        observationCenter.send(.threadSummaryChanged(snapshot.summary))
        observationCenter.send(
            .threadContextStateChanged(
                threadID: threadID,
                state: snapshot.contextState
            )
        )
        observationCenter.send(
            .threadContextUsageChanged(
                threadID: threadID,
                usage: await threadContextUsage(for: snapshot)
            )
        )
    }

    func resolveInstructions(
        thread: AgentThread,
        message: Request,
        resolvedTurnSkills: ResolvedTurnSkills
    ) async -> String {
        let baseInstructions: String?
        if let configuredBaseInstructions {
            baseInstructions = configuredBaseInstructions
        } else {
            baseInstructions = await backend.baseInstructions
        }
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

    // MARK: - Auth Recovery

    static func isUnauthorizedError(_ error: Error) -> Bool {
        (error as? AgentRuntimeError)?.code == AgentRuntimeError.unauthorized().code
    }

    func withUnauthorizedRecovery<Result: Sendable>(
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

}
