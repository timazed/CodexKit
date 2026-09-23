@testable import CodexKit
import XCTest

final class ToolAdmissionPlanTests: XCTestCase {
    private func round(_ names: [String]) -> AgentToolRound {
        .init(calls: names.map { .init(id: UUID().uuidString, threadID: "thread", turnID: "turn", toolName: $0, arguments: .null) })
    }

    private var definitions: [String: ToolDefinition] {
        Dictionary(uniqueKeysWithValues: ["a", "b", "x", "y", "serial", "approval"].map {
            ($0, policyTool($0, parallel: $0 != "serial", approval: $0 == "approval" ? .requiresApproval : .automatic).definition)
        })
    }

    func testSequenceIsAnExactPrefixWithSameRoundBarriers() async throws {
        let tracker = AgentRuntime.TurnSkillPolicyTracker(policy: .init(toolSequence: ["a", "b"]))
        let plan = try await tracker.plan(round(["a", "x", "b", "x", "y"]), definitions: definitions, maximumConcurrency: 4)
        XCTAssertEqual(plan.waves.map { $0.map(\.invocation.toolName) }, [["a"], ["x"], ["b"], ["x", "y"]])
        XCTAssertEqual(plan.waves[1][0].failure?.code, "tool_sequence_violation")
        let before = await tracker.completionError()
        XCTAssertNotNil(before, "Reservation must not satisfy required sequence calls")
        for admission in plan.waves.flatMap({ $0 }) { await tracker.recordSettled(admission) }
        let after = await tracker.completionError()
        XCTAssertNil(after)
    }

    func testSequenceCanFinishAndAllowUnrelatedCallsInNextRound() async throws {
        let tracker = AgentRuntime.TurnSkillPolicyTracker(policy: .init(toolSequence: ["a", "b"]))
        let first = try await tracker.plan(round(["a"]), definitions: definitions, maximumConcurrency: 4)
        await tracker.recordSettled(first.waves[0][0])
        let second = try await tracker.plan(round(["b", "x", "y"]), definitions: definitions, maximumConcurrency: 4)
        XCTAssertEqual(second.waves.map { $0.map(\.invocation.toolName) }, [["b"], ["x", "y"]])
        XCTAssertTrue(second.waves.flatMap { $0 }.allSatisfy { $0.failure == nil })
    }

    func testSerialAndApprovalToolsAreExclusive() async throws {
        let tracker = AgentRuntime.TurnSkillPolicyTracker(policy: .init(allowedToolNames: Array(definitions.keys)))
        let plan = try await tracker.plan(round(["a", "b", "serial", "x", "y", "approval", "a"]),
            definitions: definitions, maximumConcurrency: 4)
        XCTAssertEqual(plan.waves.map { $0.map(\.invocation.toolName) }, [["a", "b"], ["serial"], ["x", "y"], ["approval"], ["a"]])
    }

    func testRuntimeAndSkillConcurrencyUseTheSmallerLimit() async throws {
        for (runtime, skill, sizes) in [(4, 1, [1, 1, 1, 1]), (2, 8, [2, 2]), (4, 2, [2, 2])] {
            let tracker = AgentRuntime.TurnSkillPolicyTracker(policy: .init(maximumParallelToolCalls: skill))
            let plan = try await tracker.plan(round(["a", "b", "x", "y"]), definitions: definitions, maximumConcurrency: runtime)
            XCTAssertEqual(plan.waves.map(\.count), sizes)
        }
    }

    func testBudgetsReserveInProviderOrderAndNeverChargePolicyRejections() async throws {
        let tracker = AgentRuntime.TurnSkillPolicyTracker(policy: .init(allowedToolNames: ["a", "b"],
            maxToolCalls: 3, maxToolCallsByName: ["a": 1]))
        let plan = try await tracker.plan(round(["x", "a", "a", "b", "b", "b"]), definitions: definitions, maximumConcurrency: 4)
        let calls = plan.waves.flatMap { $0 }
        XCTAssertEqual(calls.map { $0.failure?.code }, ["tool_not_allowed", nil, "tool_budget_exceeded", nil, nil, "tool_budget_exceeded"])
        let next = try await tracker.plan(round(["a", "b"]), definitions: definitions, maximumConcurrency: 4)
        XCTAssertTrue(next.waves.flatMap { $0 }.allSatisfy { $0.failure?.code == "tool_budget_exceeded" })
    }

    func testFourCallsConsumeOneRoundAndZeroRoundBudgetRejectsAllCalls() async throws {
        let tracker = AgentRuntime.TurnSkillPolicyTracker(policy: .init(maxToolRounds: 1))
        let first = try await tracker.plan(round(["a", "b", "x", "y"]), definitions: definitions, maximumConcurrency: 2)
        XCTAssertTrue(first.waves.flatMap { $0 }.allSatisfy { $0.failure == nil })
        let next = try await tracker.plan(round(["a"]), definitions: definitions, maximumConcurrency: 4)
        XCTAssertEqual(next.waves[0][0].failure?.code, "tool_round_budget_exceeded")
        let zero = AgentRuntime.TurnSkillPolicyTracker(policy: .init(maxToolRounds: 0))
        let denied = try await zero.plan(round(["b"]), definitions: definitions, maximumConcurrency: 4)
        XCTAssertEqual(denied.waves[0][0].failure?.code, "tool_round_budget_exceeded")
    }

    func testDuplicateRoundAndInvocationIDsAreFatal() async throws {
        let tracker = AgentRuntime.TurnSkillPolicyTracker(policy: .init())
        let first = round(["a"])
        _ = try await tracker.plan(first, definitions: definitions, maximumConcurrency: 4)
        for duplicate in [first, AgentToolRound(calls: first.calls)] {
            do {
                _ = try await tracker.plan(duplicate, definitions: definitions, maximumConcurrency: 4)
                XCTFail("Duplicate identity must fail")
            } catch { XCTAssertEqual((error as? AgentRuntimeError)?.code, "duplicate_tool_call") }
        }
    }
}
