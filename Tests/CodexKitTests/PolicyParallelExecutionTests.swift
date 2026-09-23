@testable import CodexKit
import XCTest

final class PolicyParallelExecutionTests: XCTestCase {
    override func setUp() async throws { await TestURLProtocol.reset() }
    override func tearDown() async throws { await TestURLProtocol.reset() }

    func testAllowedPolicyAndUnconstrainedToolsActuallyOverlap() async throws {
        for policy: AgentSkillExecutionPolicy? in [nil, .init(allowedToolNames: ["a", "b"], maxToolCalls: 2)] {
            let a = expectation(description: "a started"), b = expectation(description: "b started")
            let gate = PolicyToolGate(started: ["a": a, "b": b])
            let runtime = try makePolicyRuntime(policy: policy, tools: ["a", "b"].map { name in
                policyTool(name) { invocation in
                    try await gate.enter(name)
                    return .success(invocation: invocation, text: name)
                }
            })
            let thread = try await runtime.createThread(skillIDs: policy == nil ? [] : ["policy"])
            await enqueuePolicyRound(["a", "b"])
            await enqueuePolicyAnswer()
            let task = Task { try await runtime.send(Request(text: "Go"), in: thread.id) }
            await fulfillment(of: [a, b], timeout: 3)
            let peak = await gate.peak
            XCTAssertEqual(peak, 2)
            await gate.releaseAll()
            _ = try await task.value
        }
    }

    func testSkillConcurrencyOnePreventsOverlap() async throws {
        let a = expectation(description: "a"), b = expectation(description: "b")
        let gate = PolicyToolGate(started: ["a": a, "b": b])
        let runtime = try makePolicyRuntime(policy: .init(maximumParallelToolCalls: 1), tools: ["a", "b"].map { name in
            policyTool(name) { invocation in try await gate.enter(name); return .success(invocation: invocation, text: name) }
        })
        let thread = try await runtime.createThread(skillIDs: ["policy"])
        await enqueuePolicyRound(["a", "b"])
        await enqueuePolicyAnswer()
        let task = Task { try await runtime.send(Request(text: "Go"), in: thread.id) }
        await fulfillment(of: [a], timeout: 3)
        let names = await gate.names
        XCTAssertEqual(names, ["a"])
        await gate.release("a")
        await fulfillment(of: [b], timeout: 3)
        await gate.releaseAll()
        _ = try await task.value
        let peak = await gate.peak
        XCTAssertEqual(peak, 1)
    }

    func testCompletionHistoryIsChronologicalButContextAndProviderResultsAreOrdered() async throws {
        let a = expectation(description: "a"), b = expectation(description: "b"), finishedB = expectation(description: "b finished")
        let gate = PolicyToolGate(started: ["a": a, "b": b])
        let store = InMemoryRuntimeStateStore()
        let runtime = try makePolicyRuntime(policy: .init(maxToolCalls: 2), tools: ["a", "b"].map { name in
            policyTool(name) { invocation in try await gate.enter(name); return .success(invocation: invocation, text: name) }
        }, store: store)
        let thread = try await runtime.createThread(skillIDs: ["policy"])
        await enqueuePolicyRound(["a", "b"])
        await enqueuePolicyAnswer { request in
            let body = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(requestBodyData(for: request)))
            let outputs = body.objectValue?["input"]?.arrayValue?.filter { $0.objectValue?["type"] == .string("function_call_output") }
            XCTAssertEqual(outputs?.compactMap { $0.objectValue?["call_id"]?.stringValue }, ["round-0", "round-1"])
        }
        let task = Task {
            for try await event in try await runtime.stream(Request(text: "Go"), in: thread.id) {
                if case let .toolCallFinished(result) = event, result.toolName == "b" { finishedB.fulfill() }
            }
        }
        await fulfillment(of: [a, b], timeout: 3)
        await gate.release("b")
        await fulfillment(of: [finishedB], timeout: 3)
        await gate.releaseAll()
        try await task.value
        let audit = try await runtime.execute(HistoryItemsQuery(threadID: thread.id, kinds: [.toolResult]))
        let resultNames = audit.records.sorted { $0.sequenceNumber < $1.sequenceNumber }.compactMap {
            if case let .toolResult(value) = $0.item { return value.result.toolName }; return nil
        }
        XCTAssertEqual(resultNames, ["b", "a"])
        let history = await runtime.effectiveHistory(for: thread.id)
        XCTAssertEqual(history.compactMap { $0.toolInteraction?.invocation.toolName }, ["a", "b"])
        let restored = try makePolicyRuntime(store: store)
        _ = try await restored.restore()
        _ = try await restored.resumeThread(id: thread.id)
        let restoredHistory = await restored.effectiveHistory(for: thread.id)
        XCTAssertEqual(restoredHistory.compactMap { $0.toolInteraction?.invocation.toolName }, ["a", "b"])
    }

    func testBudgetFailuresArePersistedAndFailedExecutionsConsumeBudget() async throws {
        let runtime = try makePolicyRuntime(policy: .init(maxToolCalls: 2, maxToolCallsByName: ["a": 1]), tools: [
            policyTool("a") { _ in throw NSError(domain: "test", code: 1) }, policyTool("b"),
        ])
        let thread = try await runtime.createThread(skillIDs: ["policy"])
        await enqueuePolicyRound(["a", "a", "b", "b"])
        await enqueuePolicyAnswer { request in
            let body = String(decoding: try XCTUnwrap(requestBodyData(for: request)), as: UTF8.self)
            XCTAssertTrue(body.contains("tool_budget_exceeded"))
        }
        var results: [ToolResultEnvelope] = []
        for try await event in try await runtime.stream(Request(text: "Go"), in: thread.id) {
            if case let .toolCallFinished(result) = event { results.append(result) }
        }
        XCTAssertEqual(results.count, 4)
        XCTAssertEqual(results.filter { $0.failure?.code == "tool_budget_exceeded" }.count, 2)
        XCTAssertEqual(results.filter { $0.failure?.code == "tool_execution_failed" }.count, 1)
        XCTAssertEqual(results.filter(\.success).count, 1)
        let history = try await runtime.execute(HistoryItemsQuery(threadID: thread.id, kinds: [.toolResult]))
        XCTAssertEqual(history.records.count, 4, "Policy failures must use the normal result persistence path")
    }

    func testAllSerialCallsInOneResponseConsumeOneRound() async throws {
        let runtime = try makePolicyRuntime(policy: .init(maxToolRounds: 1), tools: [policyTool("a", parallel: false)])
        let thread = try await runtime.createThread(skillIDs: ["policy"])
        await enqueuePolicyRound(["a", "a", "a", "a"], id: "first")
        await enqueuePolicyRound(["a"], id: "second")
        await enqueuePolicyAnswer()
        var results: [ToolResultEnvelope] = []
        for try await event in try await runtime.stream(Request(text: "Go"), in: thread.id) {
            if case let .toolCallFinished(result) = event { results.append(result) }
        }
        XCTAssertEqual(results.filter(\.success).count, 4)
        XCTAssertEqual(results.last?.failure?.code, "tool_round_budget_exceeded")
    }

    func testNoToolResponseSucceedsWithZeroRoundBudget() async throws {
        let runtime = try makePolicyRuntime(policy: .init(maxToolRounds: 0))
        let thread = try await runtime.createThread(skillIDs: ["policy"])
        await enqueuePolicyAnswer()
        _ = try await runtime.send(Request(text: "Go"), in: thread.id)
    }

    func testInterruptionCancelsEveryActiveConstrainedCall() async throws {
        let a = expectation(description: "a"), b = expectation(description: "b")
        let gate = PolicyToolGate(started: ["a": a, "b": b])
        let runtime = try makePolicyRuntime(policy: .init(allowedToolNames: ["a", "b"]), tools: ["a", "b"].map { name in
            policyTool(name) { invocation in try await gate.enter(name); return .success(invocation: invocation, text: name) }
        })
        let thread = try await runtime.createThread(skillIDs: ["policy"])
        await enqueuePolicyRound(["a", "b"])
        let task = Task { try await runtime.send(Request(text: "Go"), in: thread.id) }
        await fulfillment(of: [a, b], timeout: 3)
        try await runtime.interrupt(in: thread.id)
        do { _ = try await task.value; XCTFail("Expected interruption") } catch {}
        let cancelled = await gate.cancelled
        XCTAssertEqual(cancelled, ["a", "b"])
    }
}
