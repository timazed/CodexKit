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
        public let contextCompaction: AgentContextCompactionConfiguration

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
            definitionSourceLoader: AgentDefinitionSourceLoader = AgentDefinitionSourceLoader(),
            contextCompaction: AgentContextCompactionConfiguration = AgentContextCompactionConfiguration()
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
            self.contextCompaction = contextCompaction
        }
    }

    let backend: any AgentBackend
    let stateStore: any RuntimeStateStoring
    let sessionManager: ChatGPTSessionManager
    let toolRegistry: ToolRegistry
    let approvalCoordinator: ApprovalCoordinator
    let memoryConfiguration: AgentMemoryConfiguration?
    let baseInstructions: String?
    let definitionSourceLoader: AgentDefinitionSourceLoader
    let contextCompactionConfiguration: AgentContextCompactionConfiguration
    nonisolated let observationCenter: AgentRuntimeObservationCenter
    var skillsByID: [String: AgentSkill]

    var state: StoredRuntimeState = .empty
    var pendingStoreOperations: [AgentStoreWriteOperation] = []

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

    final class TurnSkillPolicyTracker: @unchecked Sendable {
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
        self.contextCompactionConfiguration = configuration.contextCompaction
        self.observationCenter = AgentRuntimeObservationCenter()
        self.skillsByID = try Self.validatedSkills(from: configuration.skills)
    }

    public nonisolated var observations: AnyPublisher<AgentRuntimeObservation, Never> {
        observationCenter.publisher
    }

    @discardableResult
    public func restore() async throws -> StoredRuntimeState {
        _ = try await sessionManager.restore()
        _ = try await stateStore.prepare()
        state = try await stateStore.loadState()
        pendingStoreOperations.removeAll()
        publishAllObservations()
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

    // MARK: - Read State

    public func threads() -> [AgentThread] {
        state.threads.sorted { $0.updatedAt > $1.updatedAt }
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

    func persistState() async throws {
        state = state.normalized()
        guard !pendingStoreOperations.isEmpty else {
            try await stateStore.saveState(state)
            publishAllObservations()
            return
        }

        let operations = pendingStoreOperations
        try await stateStore.apply(operations)
        pendingStoreOperations.removeAll()
        publishObservations(for: operations)
    }

    func enqueueStoreOperation(_ operation: AgentStoreWriteOperation) {
        pendingStoreOperations.append(operation)
    }

    func publishAllObservations() {
        observationCenter.send(.threadsChanged(threads()))
        for thread in state.threads {
            publishThreadObservations(for: thread.id)
        }
    }

    func publishObservations(for operations: [AgentStoreWriteOperation]) {
        let deletedThreadIDs = Set(operations.compactMap { operation -> String? in
            guard case let .deleteThread(threadID) = operation else {
                return nil
            }
            return threadID
        })
        let affectedThreadIDs = Set(operations.map(\.affectedThreadID))

        observationCenter.send(.threadsChanged(threads()))
        for threadID in deletedThreadIDs {
            observationCenter.send(.threadDeleted(threadID: threadID))
        }
        for threadID in affectedThreadIDs.subtracting(deletedThreadIDs) {
            publishThreadObservations(for: threadID)
        }
    }

    func publishThreadObservations(for threadID: String) {
        guard let thread = thread(for: threadID) else {
            return
        }

        observationCenter.send(.threadChanged(thread))
        observationCenter.send(
            .messagesChanged(
                threadID: threadID,
                messages: state.messagesByThread[threadID] ?? []
            )
        )
        observationCenter.send(
            .threadSummaryChanged(
                state.summariesByThread[threadID] ?? state.threadSummaryFallback(for: thread)
            )
        )
        observationCenter.send(
            .threadContextStateChanged(
                threadID: threadID,
                state: state.contextStateByThread[threadID]
            )
        )
        observationCenter.send(
            .threadContextUsageChanged(
                threadID: threadID,
                usage: threadContextUsage(for: threadID)
            )
        )
    }

    func resolveInstructions(
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
