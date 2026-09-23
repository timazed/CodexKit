@testable import CodexKit
import XCTest

final class PolicyBarrierExecutionTests: XCTestCase {
    override func setUp() async throws { await TestURLProtocol.reset() }
    override func tearDown() async throws { await TestURLProtocol.reset() }

    func testSerialAndApprovalBarriersSeparateConstrainedParallelWaves() async throws {
        for requiresApproval in [false, true] {
            let names = ["a", "b", "barrier", "c", "d"]
            let started = Dictionary(uniqueKeysWithValues: (names + (requiresApproval ? ["approval"] : [])).map {
                ($0, expectation(description: $0))
            })
            let gate = PolicyToolGate(started: started)
            let runtime = try makePolicyRuntime(policy: .init(allowedToolNames: names, maxToolCalls: 5),
                tools: names.map { name in
                    policyTool(name, parallel: name != "barrier" || requiresApproval,
                        approval: name == "barrier" && requiresApproval ? .requiresApproval : .automatic) { invocation in
                        try await gate.enter(name)
                        return .success(invocation: invocation, text: name)
                    }
                }, approvals: GatedPolicyApproval(gate: gate))
            let thread = try await runtime.createThread(skillIDs: ["policy"])
            await enqueuePolicyRound(names)
            await enqueuePolicyAnswer()
            let task = Task { try await runtime.send(Request(text: "Go"), in: thread.id) }
            await fulfillment(of: [started["a"]!, started["b"]!], timeout: 3)
            var entered = await gate.names
            XCTAssertEqual(Set(entered), ["a", "b"])
            await gate.release("a")
            await gate.release("b")
            if requiresApproval {
                await fulfillment(of: [started["approval"]!], timeout: 3)
                entered = await gate.names
                XCTAssertEqual(Set(entered), ["a", "b", "approval"])
                await gate.release("approval")
            }
            await fulfillment(of: [started["barrier"]!], timeout: 3)
            entered = await gate.names
            XCTAssertFalse(entered.contains("c") || entered.contains("d"))
            await gate.release("barrier")
            await fulfillment(of: [started["c"]!, started["d"]!], timeout: 3)
            await gate.releaseAll()
            _ = try await task.value
            let peak = await gate.peak
            XCTAssertEqual(peak, 2)
        }
    }

    func testSequenceSettlesBeforeUnrelatedCallsOverlapInTheSameRound() async throws {
        let names = ["a", "b", "x", "y"]
        let started = Dictionary(uniqueKeysWithValues: names.map { ($0, expectation(description: $0)) })
        let gate = PolicyToolGate(started: started)
        let runtime = try makePolicyRuntime(policy: .init(toolSequence: ["a", "b"], maxToolRounds: 1),
            tools: names.map { name in
                policyTool(name) { invocation in
                    try await gate.enter(name)
                    return .success(invocation: invocation, text: name)
                }
            })
        let thread = try await runtime.createThread(skillIDs: ["policy"])
        await enqueuePolicyRound(names)
        await enqueuePolicyAnswer()
        let task = Task { try await runtime.send(Request(text: "Go"), in: thread.id) }
        await fulfillment(of: [started["a"]!], timeout: 3)
        var entered = await gate.names
        XCTAssertEqual(entered, ["a"])
        await gate.release("a")
        await fulfillment(of: [started["b"]!], timeout: 3)
        entered = await gate.names
        XCTAssertEqual(entered, ["a", "b"])
        await gate.release("b")
        await fulfillment(of: [started["x"]!, started["y"]!], timeout: 3)
        await gate.releaseAll()
        _ = try await task.value
        let peak = await gate.peak
        XCTAssertEqual(peak, 2)
    }

    func testDenialAndUnknownToolConsumeBudgetAndSettleRequirements() async throws {
        let runtime = try makePolicyRuntime(policy: .init(requiredToolNames: ["guarded", "unknown"],
            toolSequence: ["guarded", "unknown"], maxToolCalls: 2), tools: [
                policyTool("guarded", approval: .requiresApproval) { invocation in
                    XCTFail("Denied calls must not execute")
                    return .success(invocation: invocation, text: "unexpected")
                }, policyTool("extra"),
            ], approvals: DeniedPolicyApproval())
        let thread = try await runtime.createThread(skillIDs: ["policy"])
        await enqueuePolicyRound(["guarded", "unknown", "extra"])
        await enqueuePolicyAnswer()
        var failures: [String?] = []
        for try await event in try await runtime.stream(Request(text: "Go"), in: thread.id) {
            if case let .toolCallFinished(result) = event { failures.append(result.failure?.code) }
        }
        XCTAssertEqual(failures, ["tool_approval_denied", "tool_unknown", "tool_budget_exceeded"])
        let history = try await runtime.execute(HistoryItemsQuery(threadID: thread.id, kinds: [.toolResult]))
        XCTAssertEqual(history.records.count, 3)
    }

    func testIndividualToolCancellationDoesNotCancelSiblingOrRefundBudget() async throws {
        let runtime = try makePolicyRuntime(policy: .init(maxToolCalls: 2), tools: [
            policyTool("cancelled") { _ in throw CancellationError() }, policyTool("ok"),
        ])
        let thread = try await runtime.createThread(skillIDs: ["policy"])
        await enqueuePolicyRound(["cancelled", "ok", "ok"])
        await enqueuePolicyAnswer()
        var results: [ToolResultEnvelope] = []
        for try await event in try await runtime.stream(Request(text: "Go"), in: thread.id) {
            if case let .toolCallFinished(result) = event { results.append(result) }
        }
        XCTAssertEqual(results.filter(\.success).count, 1)
        XCTAssertEqual(Set(results.compactMap { $0.failure?.code }), ["tool_cancelled", "tool_budget_exceeded"])
    }
}

private struct GatedPolicyApproval: ApprovalPresenting {
    let gate: PolicyToolGate
    func requestApproval(_ request: ApprovalRequest) async throws -> ApprovalDecision {
        try await gate.enter("approval")
        return .approved
    }
}

private struct DeniedPolicyApproval: ApprovalPresenting {
    func requestApproval(_ request: ApprovalRequest) async throws -> ApprovalDecision { .denied }
}
