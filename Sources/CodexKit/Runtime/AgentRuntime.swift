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
        public let tools: [ToolRegistration]

        public init(
            authProvider: any ChatGPTAuthProviding,
            secureStore: any SessionSecureStoring,
            backend: any AgentBackend,
            approvalPresenter: any ApprovalPresenting,
            stateStore: any RuntimeStateStoring,
            tools: [ToolRegistration] = []
        ) {
            self.authProvider = authProvider
            self.secureStore = secureStore
            self.backend = backend
            self.approvalPresenter = approvalPresenter
            self.stateStore = stateStore
            self.tools = tools
        }
    }

    private let backend: any AgentBackend
    private let stateStore: any RuntimeStateStoring
    private let sessionManager: ChatGPTSessionManager
    private let toolRegistry: ToolRegistry
    private let approvalCoordinator: ApprovalCoordinator

    private var state: StoredRuntimeState = .empty

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

    @discardableResult
    public func createThread(title: String? = nil) async throws -> AgentThread {
        let session = try await sessionManager.requireSession()
        var thread = try await backend.createThread(session: session)
        if let title {
            thread.title = title
        }
        try await upsertThread(thread)
        return thread
    }

    @discardableResult
    public func resumeThread(id: String) async throws -> AgentThread {
        let session = try await sessionManager.requireSession()
        let thread = try await backend.resumeThread(id: id, session: session)
        try await upsertThread(thread)
        return thread
    }

    public func sendMessage(
        _ request: UserMessageRequest,
        in threadID: String
    ) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        guard let thread = thread(for: threadID) else {
            throw AgentRuntimeError.threadNotFound(threadID)
        }

        let session = try await sessionManager.requireSession()
        let userMessage = AgentMessage(
            threadID: threadID,
            role: .user,
            text: request.text
        )
        let priorMessages = state.messagesByThread[threadID] ?? []

        try await appendMessage(userMessage)
        try await setThreadStatus(.streaming, for: threadID)

        let tools = await toolRegistry.allDefinitions()
        let turnStream = try await backend.beginTurn(
            thread: thread,
            history: priorMessages,
            message: request,
            tools: tools,
            session: session
        )

        return AsyncThrowingStream { continuation in
            continuation.yield(.messageCommitted(userMessage))
            continuation.yield(.threadStatusChanged(threadID: threadID, status: .streaming))

            Task {
                await self.consumeTurnStream(
                    turnStream,
                    for: threadID,
                    session: session,
                    continuation: continuation
                )
            }
        }
    }

    private func consumeTurnStream(
        _ turnStream: any AgentTurnStreaming,
        for threadID: String,
        session: ChatGPTSession,
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    ) async {
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

                    let result = try await resolveToolInvocation(
                        invocation,
                        session: session,
                        continuation: continuation
                    )

                    try await turnStream.submitToolResult(result, for: invocation.id)
                    continuation.yield(.toolCallFinished(result))
                    try await setThreadStatus(.streaming, for: threadID)
                    continuation.yield(.threadStatusChanged(threadID: threadID, status: .streaming))

                case let .turnCompleted(summary):
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

    private func upsertThread(_ thread: AgentThread) async throws {
        if let index = state.threads.firstIndex(where: { $0.id == thread.id }) {
            state.threads[index] = thread
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
                state.threads[index].title = String(message.text.prefix(48))
            }
        }

        try await persistState()
    }

    private func persistState() async throws {
        try await stateStore.saveState(state)
    }
}
