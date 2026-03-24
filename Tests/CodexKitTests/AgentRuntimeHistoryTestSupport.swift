import CodexKit
import CodexKitUI
import XCTest

func makeHistoryRuntime(
    backend: any AgentBackend,
    approvalPresenter: any ApprovalPresenting,
    stateStore: any RuntimeStateStoring,
    tools: [AgentRuntime.ToolRegistration] = [],
    contextCompaction: AgentContextCompactionConfiguration = AgentContextCompactionConfiguration()
) throws -> AgentRuntime {
    try AgentRuntime(configuration: .init(
        authProvider: DemoChatGPTAuthProvider(),
        secureStore: KeychainSessionSecureStore(service: "CodexKitTests.ChatGPTSession", account: UUID().uuidString),
        backend: backend,
        approvalPresenter: approvalPresenter,
        stateStore: stateStore,
        tools: tools,
        contextCompaction: contextCompaction
    ))
}

func temporaryRuntimeSQLiteURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("sqlite")
}

func messageTexts(in page: AgentThreadHistoryPage) -> [String] {
    page.items.compactMap { item in
        guard case let .message(message) = item else { return nil }
        return message.displayText
    }
}

func waitUntil(
    timeoutNanoseconds: UInt64 = 2_000_000_000,
    intervalNanoseconds: UInt64 = 20_000_000,
    condition: @escaping @Sendable () async throws -> Bool
) async throws {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while DispatchTime.now().uptimeNanoseconds < deadline {
        if try await condition() {
            return
        }
        try await Task.sleep(nanoseconds: intervalNanoseconds)
    }

    XCTFail("Timed out waiting for condition.")
}

enum TimedAsyncOperationError: Error {
    case timedOut
}

func awaitValue<T: Sendable>(
    timeoutNanoseconds: UInt64 = 500_000_000,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(nanoseconds: timeoutNanoseconds)
            throw TimedAsyncOperationError.timedOut
        }

        guard let value = try await group.next() else {
            throw TimedAsyncOperationError.timedOut
        }
        group.cancelAll()
        return value
    }
}

actor ToolExecutionGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var released = false

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        released = true
        let continuations = waiters
        waiters.removeAll()
        continuations.forEach { $0.resume() }
    }
}

private actor BeginTurnDelayGate {
    private var didStart = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        didStart = true
        let continuations = startWaiters
        startWaiters.removeAll()
        continuations.forEach { $0.resume() }
    }

    func waitForStart() async {
        guard !didStart else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func waitForRelease() async {
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let continuations = releaseWaiters
        releaseWaiters.removeAll()
        continuations.forEach { $0.resume() }
    }
}

private actor PartialEmissionGate {
    private var partialEmitted = false
    private var partialWaiters: [CheckedContinuation<Void, Never>] = []
    private var commitReleased = false
    private var commitWaiters: [CheckedContinuation<Void, Never>] = []

    func markPartialEmitted() {
        partialEmitted = true
        let continuations = partialWaiters
        partialWaiters.removeAll()
        continuations.forEach { $0.resume() }
    }

    func waitForPartialEmission() async {
        guard !partialEmitted else { return }
        await withCheckedContinuation { continuation in
            partialWaiters.append(continuation)
        }
    }

    func waitForCommitRelease() async {
        guard !commitReleased else { return }
        await withCheckedContinuation { continuation in
            commitWaiters.append(continuation)
        }
    }

    func releaseCommit() {
        commitReleased = true
        let continuations = commitWaiters
        commitWaiters.removeAll()
        continuations.forEach { $0.resume() }
    }
}

actor CompactingTestBackend: AgentBackend, AgentBackendContextCompacting, AgentBackendContextWindowProviding {
    nonisolated let baseInstructions: String? = nil
    nonisolated let modelContextWindowTokenCount: Int? = 272_000
    nonisolated let usableContextWindowTokenCount: Int? = 258_400

    private let failOnHistoryCountAbove: Int?
    private var threads: [String: AgentThread] = [:]
    private var compactCalls = 0
    private var historyCounts: [Int] = []

    init(failOnHistoryCountAbove: Int? = nil) {
        self.failOnHistoryCountAbove = failOnHistoryCountAbove
    }

    func createThread(session _: ChatGPTSession) async throws -> AgentThread {
        let thread = AgentThread(id: UUID().uuidString)
        threads[thread.id] = thread
        return thread
    }

    func resumeThread(id: String, session _: ChatGPTSession) async throws -> AgentThread {
        if let thread = threads[id] { return thread }
        let thread = AgentThread(id: id)
        threads[id] = thread
        return thread
    }

    func beginTurn(
        thread: AgentThread,
        history: [AgentMessage],
        message: UserMessageRequest,
        instructions _: String,
        responseFormat _: AgentStructuredOutputFormat?,
        streamedStructuredOutput _: AgentStreamedStructuredOutputRequest?,
        tools _: [ToolDefinition],
        session _: ChatGPTSession
    ) async throws -> any AgentTurnStreaming {
        historyCounts.append(history.count)
        if let failOnHistoryCountAbove,
           history.count > failOnHistoryCountAbove,
           !history.contains(where: { $0.role == .system && $0.text.contains("Compacted conversation summary") }) {
            throw AgentRuntimeError(code: "context_limit_exceeded", message: "Maximum context length exceeded.")
        }

        return MockAgentTurnSession(thread: thread, message: message, selectedTool: nil, structuredResponseText: nil, streamedStructuredOutput: nil)
    }

    func compactContext(
        thread: AgentThread,
        effectiveHistory: [AgentMessage],
        instructions _: String,
        tools _: [ToolDefinition],
        session _: ChatGPTSession
    ) async throws -> AgentCompactionResult {
        compactCalls += 1
        let lastUser = effectiveHistory.last(where: { $0.role == .user })
        let lastAssistant = effectiveHistory.last(where: { $0.role == .assistant })
        var compacted = [AgentMessage(threadID: thread.id, role: .system, text: "Compacted conversation summary")]
        if let lastUser { compacted.append(lastUser) }
        if let lastAssistant { compacted.append(lastAssistant) }
        return AgentCompactionResult(effectiveMessages: compacted, summaryPreview: "Compacted conversation summary")
    }

    func compactCallCount() -> Int { compactCalls }
    func beginTurnHistoryCounts() -> [Int] { historyCounts }
}

actor DelayedBeginTurnBackend: AgentBackend {
    private let gate = BeginTurnDelayGate()

    func createThread(session _: ChatGPTSession) async throws -> AgentThread {
        AgentThread(id: UUID().uuidString)
    }

    func resumeThread(id: String, session _: ChatGPTSession) async throws -> AgentThread {
        AgentThread(id: id)
    }

    func beginTurn(
        thread: AgentThread,
        history _: [AgentMessage],
        message: UserMessageRequest,
        instructions _: String,
        responseFormat _: AgentStructuredOutputFormat?,
        streamedStructuredOutput _: AgentStreamedStructuredOutputRequest?,
        tools _: [ToolDefinition],
        session _: ChatGPTSession
    ) async throws -> any AgentTurnStreaming {
        await gate.markStarted()
        await gate.waitForRelease()
        return MockAgentTurnSession(
            thread: thread,
            message: message,
            selectedTool: nil,
            structuredResponseText: nil,
            streamedStructuredOutput: nil
        )
    }

    func waitForBeginTurnStart() async {
        await gate.waitForStart()
    }

    func releaseBeginTurn() async {
        await gate.release()
    }
}

actor BlockingStructuredPartialBackend: AgentBackend {
    private let gate = PartialEmissionGate()

    func createThread(session _: ChatGPTSession) async throws -> AgentThread {
        AgentThread(id: UUID().uuidString)
    }

    func resumeThread(id: String, session _: ChatGPTSession) async throws -> AgentThread {
        AgentThread(id: id)
    }

    func beginTurn(
        thread: AgentThread,
        history _: [AgentMessage],
        message _: UserMessageRequest,
        instructions _: String,
        responseFormat _: AgentStructuredOutputFormat?,
        streamedStructuredOutput _: AgentStreamedStructuredOutputRequest?,
        tools _: [ToolDefinition],
        session _: ChatGPTSession
    ) async throws -> any AgentTurnStreaming {
        BlockingStructuredPartialTurnSession(threadID: thread.id, gate: gate)
    }

    func waitForPartialEmission() async { await gate.waitForPartialEmission() }
    func releaseCommit() async { await gate.releaseCommit() }
}

private final class BlockingStructuredPartialTurnSession: AgentTurnStreaming, @unchecked Sendable {
    let events: AsyncThrowingStream<AgentBackendEvent, Error>

    init(threadID: String, gate: PartialEmissionGate) {
        let turn = AgentTurn(id: UUID().uuidString, threadID: threadID)
        let payload: JSONValue = .object(["reply": .string("Your order is already in transit."), "priority": .string("high")])

        events = AsyncThrowingStream { continuation in
            Task {
                continuation.yield(.turnStarted(turn))
                continuation.yield(.assistantMessageDelta(threadID: threadID, turnID: turn.id, delta: "Echo: Draft a shipping reply."))
                continuation.yield(.structuredOutputPartial(payload))
                await gate.markPartialEmitted()
                await gate.waitForCommitRelease()
                continuation.yield(.structuredOutputCommitted(payload))
                continuation.yield(.assistantMessageCompleted(AgentMessage(threadID: threadID, role: .assistant, text: "Echo: Draft a shipping reply.", structuredOutput: AgentStructuredOutputMetadata(formatName: "shipping_reply_draft", payload: payload))))
                continuation.yield(.turnCompleted(AgentTurnSummary(threadID: threadID, turnID: turn.id, usage: AgentUsage(inputTokens: 1, outputTokens: 1))))
                continuation.finish()
            }
        }
    }

    func submitToolResult(_: ToolResultEnvelope, for _: String) async throws {}
}
