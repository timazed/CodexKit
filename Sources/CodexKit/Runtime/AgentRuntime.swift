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


    let backend: any AgentBackend
    let stateStore: any RuntimeStateStoring
    let sessionManager: any AgentSessionProviding
    let logger: AgentLogger
    let maximumParallelToolCalls: Int
    let maximumBufferedEvents: Int
    let turnLimits: AgentTurnLimits
    var activeTurnExecutions: [String: AgentActiveTurnExecution] = [:]
    var threadOperations: [String: UUID] = [:]
    var deferredThreadDeactivations: Set<String> = []
    var isRestoring = false
    var parallelToolWaits: [String: [String: AgentPendingToolWaitState]] = [:]
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
        self.maximumParallelToolCalls = configuration.maximumParallelToolCalls
        self.maximumBufferedEvents = configuration.maximumBufferedEvents
        try configuration.turnLimits.validate()
        self.turnLimits = configuration.turnLimits
        self.backend = configuration.backend
        self.stateStore = configuration.stateStore
        self.logger = AgentLogger(configuration: configuration.logging)
        self.sessionManager = configuration.makeSessionProvider()
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
        try Task.checkCancellation()
        guard !isRestoring, threadOperations.isEmpty, resumingThreadIDs.isEmpty,
              activePersistenceTask == nil, pendingStoreOperations.isEmpty else {
            throw AgentRuntimeError(code: "runtime_busy", message: "Wait for active runtime operations before restoring state.")
        }
        isRestoring = true
        defer { isRestoring = false }
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
        guard let manager = sessionManager as? any AgentSessionManaging else { throw AgentRuntimeError.sessionManagementUnsupported() }
        let session = try await manager.signIn()
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
        guard let manager = sessionManager as? any AgentSessionManaging else { throw AgentRuntimeError.sessionManagementUnsupported() }
        return try await manager.useSession(session)
    }

    public func currentSession() async -> ChatGPTSession? {
        await sessionManager.currentSession()
    }

    public func signOut() async throws {
        logger.info(.auth, "Signing out current session.")
        guard let manager = sessionManager as? any AgentSessionManaging else { throw AgentRuntimeError.sessionManagementUnsupported() }
        try await manager.signOut()
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

    // MARK: - Auth Recovery

    static func isUnauthorizedError(_ error: Error) -> Bool {
        guard let error = error as? AgentRuntimeError else { return false }
        if let status = error.http?.statusCode { return status == 401 || status == 403 }
        return error.code == AgentRuntimeError.unauthorized().code
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
            try Task.checkCancellation()
            guard recoveredSession.account.id == initialSession.account.id else { throw CancellationError() }
            return (try await operation(recoveredSession), recoveredSession)
        }
    }

}
