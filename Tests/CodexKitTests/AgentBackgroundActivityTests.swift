import CodexKit
import XCTest

final class AgentBackgroundActivityTests: XCTestCase {
    func testCompletedTurnBeginsAndEndsBackgroundActivity() async throws {
        let provider = RecordingBackgroundActivityProvider()
        let runtime = try makeRuntime(
            backend: InMemoryAgentBackend(),
            backgroundActivityProvider: provider
        )
        _ = try await runtime.restore()
        _ = try await runtime.useSession(demoSession())
        let thread = try await runtime.createThread()

        let response = try await runtime.send(Request(text: "Hello"), in: thread.id)

        XCTAssertEqual(response, "Echo: Hello")
        try await waitUntil {
            let counts = await provider.counts()
            return counts == ActivityCounts(begun: 1, ended: 1)
        }
    }

    func testActivityExpirationCancelsTurnThroughBackendStream() async throws {
        let provider = RecordingBackgroundActivityProvider()
        let probe = TurnCancellationProbe()
        let runtime = try makeRuntime(
            backend: CancellationAwareBackend(probe: probe),
            backgroundActivityProvider: provider
        )
        _ = try await runtime.restore()
        _ = try await runtime.useSession(demoSession())
        let thread = try await runtime.createThread()
        let stream = try await runtime.stream(Request(text: "Keep working"), in: thread.id)

        let drainTask = Task {
            for try await _ in stream {}
        }

        try await waitUntil {
            let started = await probe.hasStarted()
            let hasExpirationHandler = await provider.hasActiveExpirationHandler()
            return started && hasExpirationHandler
        }
        await provider.expire()

        do {
            try await drainTask.value
            XCTFail("Expected the expired activity to cancel the turn.")
        } catch is CancellationError {
            // Expected.
        }

        try await waitUntil {
            await probe.wasCancelled()
        }
        let counts = await provider.counts()
        let status = await runtime.activeThreads().first?.status
        XCTAssertEqual(counts, ActivityCounts(begun: 1, ended: 1))
        XCTAssertEqual(status, .failed)
    }

    private func makeRuntime(
        backend: any AgentBackend,
        backgroundActivityProvider: any AgentBackgroundActivityProviding
    ) throws -> AgentRuntime {
        try AgentRuntime(configuration: .init(
            authProvider: DemoChatGPTAuthProvider(),
            secureStore: KeychainSessionSecureStore(
                service: "CodexKitTests.ChatGPTSession",
                account: UUID().uuidString
            ),
            backend: backend,
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: InMemoryRuntimeStateStore(),
            backgroundActivityProvider: backgroundActivityProvider
        ))
    }
}

private struct ActivityCounts: Equatable, Sendable {
    let begun: Int
    let ended: Int
}

private actor RecordingBackgroundActivityProvider: AgentBackgroundActivityProviding {
    private var begun = 0
    private var ended = 0
    private var expirationHandler: (@Sendable () -> Void)?

    func beginActivity(
        named _: String,
        expirationHandler: @escaping @Sendable () -> Void
    ) async -> any AgentBackgroundActivity {
        begun += 1
        self.expirationHandler = expirationHandler
        return RecordingBackgroundActivity { [weak self] in
            Task { await self?.recordEnd() }
        }
    }

    func counts() -> ActivityCounts {
        ActivityCounts(begun: begun, ended: ended)
    }

    func hasActiveExpirationHandler() -> Bool {
        expirationHandler != nil
    }

    func expire() {
        let handler = expirationHandler
        expirationHandler = nil
        handler?()
    }

    private func recordEnd() {
        ended += 1
        expirationHandler = nil
    }
}

private final class RecordingBackgroundActivity: AgentBackgroundActivity, @unchecked Sendable {
    private let lock = NSLock()
    private let onEnd: @Sendable () -> Void
    private var hasEnded = false

    init(onEnd: @escaping @Sendable () -> Void) {
        self.onEnd = onEnd
    }

    func end() {
        lock.lock()
        guard !hasEnded else {
            lock.unlock()
            return
        }
        hasEnded = true
        lock.unlock()
        onEnd()
    }
}

private actor TurnCancellationProbe {
    private var started = false
    private var cancelled = false

    func recordStart() {
        started = true
    }

    func recordCancellation() {
        cancelled = true
    }

    func hasStarted() -> Bool {
        started
    }

    func wasCancelled() -> Bool {
        cancelled
    }
}

private actor CancellationAwareBackend: AgentBackend {
    nonisolated let baseInstructions: String? = nil
    nonisolated let defaultThreadConfiguration: AgentThreadConfiguration? = nil
    private let probe: TurnCancellationProbe

    init(probe: TurnCancellationProbe) {
        self.probe = probe
    }

    func createThread(session _: ChatGPTSession) async throws -> AgentThread {
        AgentThread(id: UUID().uuidString)
    }

    func resumeThread(id: String, session _: ChatGPTSession) async throws -> AgentThread {
        AgentThread(id: id)
    }

    func beginTurn(
        thread: AgentThread,
        history _: [AgentMessage],
        message _: Request,
        instructions _: String,
        responseFormat _: AgentStructuredOutputFormat?,
        streamedStructuredOutput _: AgentStreamedStructuredOutputRequest?,
        tools _: [ToolDefinition],
        session _: ChatGPTSession
    ) async throws -> AgentTurnStream {
        let probe = probe
        let turn = AgentTurn(id: UUID().uuidString, threadID: thread.id)
        let events = AsyncThrowingStream<AgentBackendEvent, Error> { continuation in
            let producerTask = Task {
                continuation.yield(.turnStarted(turn))
                await probe.recordStart()
                do {
                    try await Task.sleep(for: .seconds(60))
                    continuation.finish()
                } catch {
                    await probe.recordCancellation()
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable termination in
                if case .cancelled = termination {
                    producerTask.cancel()
                }
            }
        }
        return AgentTurnStream(events: events) { _, _ in }
    }
}
