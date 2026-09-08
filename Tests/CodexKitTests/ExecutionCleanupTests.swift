@testable import CodexKit
import XCTest

final class ExecutionCleanupTests: XCTestCase {
    func testCancellationAfterReadinessBeforeConsumptionInterruptsBackend() async throws {
        for structured in [false, true] {
            let probe = ExecutionCleanupProbe()
            defer { probe.release() }
            let runtime = try makeRuntime(probe: probe)
            let thread = try await runtime.createThread()
            if structured {
                let execution = try await runtime.start(Request(text: "Go"), in: thread.id, response: CleanupOutput.self)
                try await execution.waitUntilReady()
                execution.cancel()
                do { for try await _ in execution.events {}; XCTFail("Expected cancellation") }
                catch is CancellationError {}
            } else {
                let execution = try await runtime.start(Request(text: "Go"), in: thread.id)
                try await execution.waitUntilReady()
                execution.cancel()
                do { for try await _ in execution.events {}; XCTFail("Expected cancellation") }
                catch is CancellationError {}
            }
            XCTAssertEqual(probe.interruptions, 1, "The runtime ended without releasing its backend")
            XCTAssertFalse(probe.isRetainingStream)
        }
    }

    func testDeadlineBeforeConsumptionInterruptsBackend() async throws {
        let probe = ExecutionCleanupProbe()
        defer { probe.release() }
        let runtime = try makeRuntime(probe: probe, duration: 0.05)
        let thread = try await runtime.createThread()
        let execution = try await runtime.start(Request(text: "Go"), in: thread.id)
        try await execution.waitUntilReady()
        try await Task.sleep(for: .milliseconds(150))
        do { for try await _ in execution.events {}; XCTFail("Expected deadline failure") }
        catch { XCTAssertEqual((error as? AgentRuntimeError)?.executionLimit, .duration) }
        XCTAssertEqual(probe.interruptions, 1)
        XCTAssertFalse(probe.isRetainingStream)
    }

    func testNormalCompletionInterruptsBackendOnlyOnce() async throws {
        let probe = ExecutionCleanupProbe()
        defer { probe.release() }
        let runtime = try makeRuntime(probe: probe, completes: true)
        let thread = try await runtime.createThread()
        let result = try await runtime.send(Request(text: "Go"), in: thread.id)
        XCTAssertEqual(result, "Done")
        XCTAssertEqual(probe.interruptions, 1)
        XCTAssertFalse(probe.isRetainingStream)
    }

    private func makeRuntime(probe: ExecutionCleanupProbe, duration: TimeInterval = 3,
        completes: Bool = false) throws -> AgentRuntime {
        try AgentRuntime(configuration: .init(sessionProvider: DesignReadOnlyProvider(),
            backend: ExecutionCleanupBackend(probe: probe, completes: completes),
            approvalPresenter: AutoApprovalPresenter(), stateStore: InMemoryRuntimeStateStore(),
            maximumBufferedEvents: 1, turnLimits: .init(maximumDuration: duration)))
    }
}

private final class ExecutionCleanupProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var stream: AsyncThrowingStream<AgentBackendEvent, Error>.Continuation?
    var interruptions: Int { lock.withLock { count } }
    var isRetainingStream: Bool { lock.withLock { stream != nil } }

    func install(_ continuation: AsyncThrowingStream<AgentBackendEvent, Error>.Continuation) {
        lock.withLock { stream = continuation }
    }
    func interrupt() {
        lock.withLock { count += 1 }
        release()
    }
    func release() {
        let continuation = lock.withLock {
            defer { stream = nil }
            return stream
        }
        continuation?.finish(throwing: CancellationError())
    }
}

private struct ExecutionCleanupBackend: AgentBackend {
    let probe: ExecutionCleanupProbe
    let completes: Bool
    func createThread(session: ChatGPTSession) async throws -> AgentThread { .init(id: UUID().uuidString) }
    func resumeThread(id: String, session: ChatGPTSession) async throws -> AgentThread { .init(id: id) }
    func beginTurn(thread: AgentThread, history: [AgentMessage], message: Request, instructions: String,
        responseFormat: AgentStructuredOutputFormat?, streamedStructuredOutput: AgentStreamedStructuredOutputRequest?,
        tools: [ToolDefinition], session: ChatGPTSession) async throws -> AgentTurnStream {
        let events = AsyncThrowingStream<AgentBackendEvent, Error> { continuation in
            probe.install(continuation)
            continuation.yield(.turnStarted(.init(id: "turn", threadID: thread.id)))
            if completes {
                continuation.yield(.assistantMessageCompleted(.init(threadID: thread.id, role: .assistant, text: "Done")))
                continuation.yield(.turnCompleted(.init(threadID: thread.id, turnID: "turn")))
                continuation.finish()
            }
        }
        return AgentTurnStream(events: events, steer: nil, interrupt: { probe.interrupt() })
    }
}

private struct CleanupOutput: AgentStructuredOutput {
    let value: String
    static let responseFormat = AgentStructuredOutputFormat(name: "result", schema: .object(properties: ["value": .string()]))
}
