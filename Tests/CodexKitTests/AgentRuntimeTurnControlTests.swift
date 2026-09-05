@testable import CodexKit
import CodexKitUI
import XCTest

final class AgentRuntimeTurnControlTests: XCTestCase {
    override func setUp() async throws { await TestURLProtocol.reset() }
    override func tearDown() async throws { await TestURLProtocol.reset() }

    private func runtime(tools: [AgentRuntime.ToolRegistration] = [], maxParallel: Int = 4,
                         approvals: any ApprovalPresenting = AlwaysApprove()) async throws -> AgentRuntime {
        let runtime = try AgentRuntime(configuration: .init(authProvider: DemoChatGPTAuthProvider(),
            secureStore: .init(service: "CodexKitTests.TurnControl", account: UUID().uuidString),
            backend: CodexResponsesBackend(configuration: .init(requestRetryPolicy: .init(maxAttempts: 1)),
                urlSession: makeTestURLSession()), approvalPresenter: approvals,
            stateStore: InMemoryRuntimeStateStore(), maximumParallelToolCalls: maxParallel, tools: tools))
        _ = try await runtime.useSession(.init(accessToken: "test", refreshToken: "refresh",
            account: .init(id: "test", email: "test@example.com", plan: .plus)))
        return runtime
    }
    private func enqueueCalls(_ names: [String]) async {
        let calls = names.enumerated().map { index, name in
            "data: {\"type\":\"response.output_item.done\",\"output_index\":\(index),\"item\":{\"type\":\"function_call\",\"name\":\"\(name)\",\"call_id\":\"call-\(index)\",\"arguments\":\"{}\"}}\n\n"
        }.joined()
        await TestURLProtocol.enqueue(.init(body: Data((calls + "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"r1\"}}\n\n").utf8)))
    }
    private func enqueueAnswer(inspect: @escaping @Sendable (URLRequest) throws -> Void = { _ in }) async {
        await TestURLProtocol.enqueue(.init(body: Data("""
        data: {"type":"response.output_item.done","item":{"id":"answer","type":"message","role":"assistant","phase":"final_answer","content":[{"type":"output_text","text":"Done"}]}}

        data: {"type":"response.completed","response":{"id":"r2"}}

        """.utf8), inspect: inspect))
    }

    func testParallelToolsOverlapAndSerialToolsAreBarriersWithOrderedProviderResults() async throws {
        let probe = ToolOverlapProbe()
        let tools = ["a", "b", "serial", "c", "d"].map { name in
            AgentRuntime.ToolRegistration(definition: .init(name: name, description: name,
                inputSchema: .object([:]), supportsParallelExecution: name != "serial"), executor: .init { invocation, _ in
                    try await probe.run(name: name, parallel: name != "serial")
                    return .success(invocation: invocation, text: name)
                })
        }
        let runtime = try await runtime(tools: tools, maxParallel: 2)
        let thread = try await runtime.createThread()
        await enqueueCalls(["a", "b", "serial", "c", "d"])
        await enqueueAnswer { request in
            let body = try XCTUnwrap(requestBodyData(for: request))
            let value = try JSONDecoder().decode(JSONValue.self, from: body)
            let outputs = value.objectValue?["input"]?.arrayValue?.filter { $0.objectValue?["type"]?.stringValue == "function_call_output" }
            XCTAssertEqual(outputs?.compactMap { $0.objectValue?["call_id"]?.stringValue }, (0..<5).map { "call-\($0)" })
        }
        let stream = try await runtime.stream(Request(text: "Look up everything"), in: thread.id)
        var successes = 0
        for try await event in stream {
            if case let .toolCallFinished(result) = event { XCTAssertTrue(result.success); successes += 1 }
        }
        XCTAssertEqual(successes, 5)
        let peak = await probe.peak
        let violations = await probe.violations
        XCTAssertEqual(peak, 2)
        XCTAssertEqual(violations, 0)
    }

    func testApprovalToolRemainsExclusiveEvenWhenMarkedParallel() async throws {
        let probe = ToolOverlapProbe()
        let tools = ["first", "guarded", "last"].map { name in
            AgentRuntime.ToolRegistration(definition: .init(name: name, description: name,
                inputSchema: .object([:]), approvalPolicy: name == "guarded" ? .requiresApproval : .automatic,
                supportsParallelExecution: true), executor: .init { invocation, _ in
                    try await probe.run(name: name, parallel: false)
                    return .success(invocation: invocation, text: name)
                })
        }
        let runtime = try await runtime(tools: tools)
        let thread = try await runtime.createThread()
        await enqueueCalls(["first", "guarded", "last"])
        await enqueueAnswer()
        let stream = try await runtime.stream(Request(text: "Run"), in: thread.id)
        for try await _ in stream {}
        let peak = await probe.peak
        let violations = await probe.violations
        XCTAssertEqual(peak, 1)
        XCTAssertEqual(violations, 0)
    }

    func testStructuredStreamAlsoExecutesParallelBatchesAndForwardsProgress() async throws {
        let probe = ToolOverlapProbe()
        let tools = ["a", "b"].map { name in
            AgentRuntime.ToolRegistration(definition: .init(name: name, description: name,
                inputSchema: .object([:]), supportsParallelExecution: true), executor: .init { invocation, _ in
                    try await probe.run(name: name, parallel: true)
                    return .success(invocation: invocation, text: name)
                })
        }
        let runtime = try await runtime(tools: tools)
        let thread = try await runtime.createThread()
        await enqueueCalls(["a", "b"])
        await enqueueAnswer()
        let stream = try await runtime.stream(Request(text: "Run"), in: thread.id, response: ShippingReplyDraft.self)
        var completed = false
        var sawProgress = false
        for try await event in stream {
            if case .turnCompleted = event { completed = true }
            if case .progress = event { sawProgress = true }
        }
        XCTAssertTrue(completed)
        XCTAssertTrue(sawProgress)
        let peak = await probe.peak
        XCTAssertEqual(peak, 2)
    }

    func testSteeringStaysInSameTurnAndRejectsStaleIDAndConcurrentSend() async throws {
        let tools: [AgentRuntime.ToolRegistration] = [.init(definition: .init(name: "lookup", description: "Lookup", inputSchema: .object([:])), executor: .init { invocation, _ in
            try await Task.sleep(for: .milliseconds(100))
            return .success(invocation: invocation, text: "Found")
        })]
        let runtime = try await runtime(tools: tools)
        let thread = try await runtime.createThread()
        await enqueueCalls(["lookup"])
        await enqueueAnswer { request in
            let text = String(decoding: try XCTUnwrap(requestBodyData(for: request)), as: UTF8.self)
            XCTAssertTrue(text.contains("Focus on recent results"))
        }
        let stream = try await runtime.stream(Request(text: "Lookup"), in: thread.id)
        var turnID = ""
        var started = 0
        var accepted = 0
        for try await event in stream {
            switch event {
            case let .turnStarted(turn): turnID = turn.id; started += 1
            case .toolCallStarted:
                do {
                    try await runtime.steer("Wrong", in: thread.id, expectedTurnID: "old")
                    XCTFail("Stale steering must fail")
                } catch let error as AgentRuntimeError { XCTAssertEqual(error.code, "turn_not_active") }
                do {
                    _ = try await runtime.stream(Request(text: "Concurrent"), in: thread.id)
                    XCTFail("Concurrent turns must be rejected")
                } catch let error as AgentRuntimeError { XCTAssertEqual(error.code, "thread_busy") }
                try await runtime.steer("Focus on recent results", in: thread.id, expectedTurnID: turnID)
            case let .messageCommitted(message) where message.text == "Focus on recent results": accepted += 1
            case let .turnCompleted(summary): XCTAssertEqual(summary.turnID, turnID)
            default: break
            }
        }
        XCTAssertEqual(started, 1)
        XCTAssertEqual(accepted, 1)
        let messages = await runtime.messages(for: thread.id)
        XCTAssertTrue(messages.contains { $0.role == .user && $0.text == "Focus on recent results" })
        XCTAssertFalse(messages.contains { $0.text == "Concurrent" || $0.text == "Wrong" })
    }

    func testInterruptDuringApprovalClearsInboxAndPersistsInterruptedStatus() async throws {
        let inbox = await MainActor.run { ApprovalInbox() }
        let tool = AgentRuntime.ToolRegistration(definition: .init(name: "sensitive", description: "Sensitive",
            inputSchema: .object([:]), approvalPolicy: .requiresApproval), executor: .init { invocation, _ in
                XCTFail("Interrupted approval must not execute its tool")
                return .success(invocation: invocation, text: "Unexpected")
            })
        let runtime = try await runtime(tools: [tool], approvals: inbox)
        let thread = try await runtime.createThread()
        await enqueueCalls(["sensitive"])
        let stream = try await runtime.stream(Request(text: "Run"), in: thread.id)
        var turnID: String?
        var interrupted = false
        do {
            for try await event in stream {
                if case let .turnStarted(turn) = event { turnID = turn.id }
                if case .approvalRequested = event { try await runtime.interrupt(in: thread.id, expectedTurnID: turnID) }
                if case let .turnInterrupted(value) = event { interrupted = true; XCTAssertEqual(value.turnID, turnID) }
                if case .turnCompleted = event { XCTFail("Interrupted turn cannot complete") }
            }
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        XCTAssertTrue(interrupted)
        let pendingApproval = await inbox.currentRequest
        XCTAssertNil(pendingApproval)
        let summary = try await runtime.fetchThreadSummary(id: thread.id)
        XCTAssertEqual(summary.latestTurnStatus, .interrupted)
        let status = await runtime.thread(for: thread.id)?.status
        XCTAssertEqual(status, .idle)
    }

    func testBackendInterruptReleasesPendingToolContinuation() async throws {
        let backend = CodexResponsesBackend(configuration: .init(requestRetryPolicy: .init(maxAttempts: 1)), urlSession: makeTestURLSession())
        await enqueueCalls(["lookup"])
        let stream = try await backend.beginTurn(thread: .init(id: "thread"), history: [], message: Request(text: "Run"),
            instructions: "Help", responseFormat: nil, streamedStructuredOutput: nil,
            tools: [.init(name: "lookup", description: "Lookup", inputSchema: .object([:]))],
            session: .init(accessToken: "t", refreshToken: "r", account: .init(id: "test", email: "a@b.com", plan: .plus)))
        do {
            for try await event in stream.events {
                if case .toolCallRequested = event { stream.interrupt() }
            }
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
    }
}

private struct AlwaysApprove: ApprovalPresenting {
    func requestApproval(_ request: ApprovalRequest) async throws -> ApprovalDecision { .approved }
}

private actor ToolOverlapProbe {
    var active = 0
    var peak = 0
    var violations = 0
    private var generation = 0

    func run(name: String, parallel: Bool) async throws {
        active += 1
        peak = max(peak, active)
        if !parallel && active != 1 { violations += 1 }
        defer { active -= 1 }
        if !parallel { try await Task.sleep(for: .milliseconds(20)) }
        if parallel {
            let current = generation
            if active == 2 { generation += 1 }
            let deadline = Date().addingTimeInterval(2)
            while generation == current && Date() < deadline {
                try await Task.sleep(for: .milliseconds(1))
            }
            if generation == current { throw AgentRuntimeError(code: "no_overlap", message: "Parallel tools never overlapped") }
        }
    }
}
