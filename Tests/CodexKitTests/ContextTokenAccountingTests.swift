@testable import CodexKit
import XCTest

final class ContextTokenAccountingTests: XCTestCase {
    override func setUp() async throws { await TestURLProtocol.reset() }
    override func tearDown() async throws { await TestURLProtocol.reset() }

    func testUnreportedReasoningRemainsOutsideLastUsableUsageBoundary() async throws {
        let backend = CodexResponsesBackend(urlSession: makeTestURLSession())
        var context: AgentProviderContext?
        let reports = [#"{"input_tokens":100,"output_tokens":20}"#, "null", #"{"codex_rollout_budget_units":3}"#]
        for (index, report) in reports.enumerated() {
            let text = String(repeating: "r", count: 4_000)
            await TestURLProtocol.enqueue(.init(body: Data("""
            data: {"type":"response.output_item.done","item":{"type":"reasoning","id":"r-\(index)","encrypted_content":"\(text)"}}

            data: {"type":"response.completed","response":{"id":"resp-\(index)","usage":\(report)}}

            """.utf8)))
            let stream = try await backend.beginTurn(thread: .init(id: "thread"), history: [], providerContext: context,
                message: Request(text: "Go"), instructions: "", responseFormat: nil,
                streamedStructuredOutput: nil, tools: [], session: demoSession())
            for try await event in stream.events {
                if case let .providerContextUpdated(_, value) = event { context = value }
            }
            let state = try XCTUnwrap(CodexResponsesProviderState(context: context))
            XCTAssertEqual(state.contextUsage?.tokens, 120)
            XCTAssertEqual(state.contextUsage?.coveredItemCount, 2)
            let estimate = CodexContextUsage.estimate(context: context, history: [])
            XCTAssertGreaterThanOrEqual(estimate, 120 + index * 1_000)
            XCTAssertLessThan(estimate, 130 + index * 1_010)
            context = try JSONDecoder().decode(AgentProviderContext.self, from: JSONEncoder().encode(context))
        }
    }

    func testEmptyCompletedResponseStillCoversItsInput() async throws {
        await TestURLProtocol.enqueue(.init(body: Data("""
        data: {"type":"response.completed","response":{"id":"resp","usage":{"input_tokens":75,"output_tokens":0}}}

        """.utf8)))
        let backend = CodexResponsesBackend(urlSession: makeTestURLSession())
        let stream = try await backend.beginTurn(thread: .init(id: "thread"), history: [], message: Request(text: "Go"),
            instructions: "", responseFormat: nil, streamedStructuredOutput: nil, tools: [], session: demoSession())
        var context: AgentProviderContext?
        for try await event in stream.events {
            if case let .providerContextUpdated(_, value) = event { context = value }
        }
        let state = try XCTUnwrap(CodexResponsesProviderState(context: context))
        XCTAssertEqual(state.contextUsage?.coveredItemCount, 1)
        XCTAssertEqual(CodexContextUsage.estimate(context: context, history: []), 75)
    }

    func testInvalidSavedBoundaryFallsBackToAllProviderItems() {
        let item: JSONValue = .object(["type": .string("reasoning"), "encrypted_content": .string(String(repeating: "r", count: 4_000))])
        for covered in [-1.0, 0.5, 99] {
            let context = AgentProviderContext(providerID: "openai.responses", payload: .object([
                "items": .array([item]), "context_usage": .object(["tokens": .number(1), "covered_items": .number(covered)])]))
            XCTAssertEqual(CodexContextUsage.estimate(context: context, history: []), 1_000)
        }
    }

    func testCompactionEstimateIncludesToolArgumentsAndResults() async throws {
        let runtime = try AgentRuntime(configuration: .init(sessionProvider: DesignReadOnlyProvider(), backend: DesignBackend(),
            approvalPresenter: AutoApprovalPresenter(), stateStore: InMemoryRuntimeStateStore()))
        let invocation = ToolInvocation(id: "call", threadID: "thread", turnID: "turn", toolName: "lookup", arguments: .object(["query": .string(String(repeating: "a", count: 4_000))]))
        let result = ToolResultEnvelope(invocationID: "call", toolName: "lookup", success: true,
            content: [.text(String(repeating: "b", count: 4_000))])
        let message = AgentMessage(threadID: "thread", role: .tool, text: "done",
            toolInteraction: .init(invocation: invocation, result: result))
        let estimate = await runtime.approximateTokenCount(for: [message], pendingMessage: nil, instructions: "")
        XCTAssertGreaterThanOrEqual(estimate, 2_000)
    }
}
