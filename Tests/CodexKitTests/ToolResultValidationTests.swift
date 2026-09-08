@testable import CodexKit
import XCTest

final class ToolResultValidationTests: XCTestCase {
    override func setUp() async throws { await TestURLProtocol.reset() }
    override func tearDown() async throws { await TestURLProtocol.reset() }

    func testBackendRejectsUnsolicitedResultsBeforeAndAfterATurn() async throws {
        let stream = try await begin()
        let unknown = ToolInvocation(id: "unknown", threadID: "thread", turnID: "turn",
            toolName: "lookup", arguments: .null)
        for try await event in stream.events {
            if case .turnStarted = event {
                await assertRejected(stream, result: .success(invocation: unknown, text: "Unsolicited"), for: unknown.id)
            }
            if case let .toolCallRequested(invocation) = event {
                try await stream.submitToolResult(.success(invocation: invocation, text: "Valid"), for: invocation.id)
            }
        }
        await assertRejected(stream, result: .success(invocation: unknown, text: "Late"), for: unknown.id)
    }

    func testBackendRejectsMismatchedResultsWithoutConsumingTheExpectedCall() async throws {
        let stream = try await begin()
        for try await event in stream.events {
            guard case let .toolCallRequested(invocation) = event else { continue }
            for result in [
                ToolResultEnvelope(invocationID: "other", toolName: invocation.toolName, success: true),
                ToolResultEnvelope(invocationID: invocation.id, toolName: "other", success: true),
            ] {
                await assertRejected(stream, result: result, for: invocation.id)
            }
            try await stream.submitToolResult(.success(invocation: invocation, text: "Valid"), for: invocation.id)
        }
    }

    func testBackendRejectsDuplicateOutOfOrderResultsAndPreservesFirstSubmission() async throws {
        let stream = try await begin(parallel: true)
        for try await event in stream.events {
            guard case let .toolCallsRequested(invocations) = event else { continue }
            XCTAssertEqual(invocations.count, 2)
            let first = invocations[0]
            let second = invocations[1]
            try await stream.submitToolResult(.success(invocation: second, text: "Second valid"), for: second.id)
            await assertRejected(stream, result: .success(invocation: second, text: "Duplicate"), for: second.id)
            try await stream.submitToolResult(.success(invocation: first, text: "First valid"), for: first.id)
        }
    }

    func testExecutorCannotReturnAnotherCallsIdentity() async {
        let invocation = ToolInvocation(id: "expected", threadID: "thread", turnID: "turn",
            toolName: "lookup", arguments: .null)
        for result in [
            ToolResultEnvelope(invocationID: "other", toolName: invocation.toolName, success: true, content: [.text("Wrong call")]),
            ToolResultEnvelope(invocationID: invocation.id, toolName: "other", success: true, content: [.text("Wrong tool")]),
        ] {
            let entry = ToolRegistry.Entry(definition: .init(name: "lookup", description: "lookup", inputSchema: .object([:])),
                executor: .init { _, _ in result })
            let received = await entry.execute(invocation, session: nil)
            XCTAssertFalse(received.success)
            XCTAssertEqual(received.invocationID, invocation.id)
            XCTAssertEqual(received.toolName, invocation.toolName)
            XCTAssertNotNil(received.errorMessage)
        }
    }

    func testInterruptionReleasesPendingCallsAndRejectsLateResults() async throws {
        let stream = try await begin(parallel: true)
        var first: ToolInvocation?
        do {
            for try await event in stream.events {
                guard case let .toolCallsRequested(invocations) = event else { continue }
                first = invocations[0]
                let second = invocations[1]
                try await stream.submitToolResult(.success(invocation: second, text: "Buffered"), for: second.id)
                stream.interrupt()
            }
            XCTFail("Expected interruption while waiting for the first result")
        } catch { XCTAssertTrue(error is CancellationError) }
        let invocation = try XCTUnwrap(first)
        await assertRejected(stream, result: .success(invocation: invocation, text: "Late"), for: invocation.id)
    }

    func testRuntimePersistsExecutorMismatchAsFailureOfTheOriginalCall() async throws {
        await enqueueResponses(parallel: false)
        let runtime = try AgentRuntime(configuration: .init(sessionProvider: ToolValidationSessionProvider(),
            backend: CodexResponsesBackend(configuration: .init(maximumBufferedEvents: 1), urlSession: makeTestURLSession()),
            approvalPresenter: AutoApprovalPresenter(), stateStore: InMemoryRuntimeStateStore(), tools: [.init(
                definition: .init(name: "lookup", description: "lookup", inputSchema: .object([:])),
                executor: .init { _, _ in
                    .init(invocationID: "wrong", toolName: "other", success: true, content: [.text("Wrong result")])
                })]))
        let thread = try await runtime.createThread()
        _ = try await runtime.send(Request(text: "Go"), in: thread.id)
        let history = try await runtime.execute(HistoryItemsQuery(threadID: thread.id, kinds: [.toolResult]))
        XCTAssertEqual(history.records.count, 1)
        guard case let .toolResult(record) = history.records.first?.item else { return XCTFail("Missing tool result") }
        XCTAssertFalse(record.result.success)
        XCTAssertEqual(record.result.invocationID, "call-0")
        XCTAssertEqual(record.result.toolName, "lookup")
        XCTAssertNotNil(record.result.errorMessage)
    }

    private func assertRejected(_ stream: AgentTurnStream, result: ToolResultEnvelope, for id: String,
        file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await stream.submitToolResult(result, for: id)
            XCTFail("Expected an invalid tool result to be rejected", file: file, line: line)
        } catch {
            XCTAssertEqual((error as? AgentRuntimeError)?.code, "invalid_tool_result", file: file, line: line)
        }
    }

    private func begin(parallel: Bool = false) async throws -> AgentTurnStream {
        await enqueueResponses(parallel: parallel)
        let backend = CodexResponsesBackend(configuration: .init(maximumBufferedEvents: 1), urlSession: makeTestURLSession())
        return try await backend.beginTurn(thread: .init(id: "thread"), history: [], message: Request(text: "Go"),
            instructions: "", responseFormat: nil, streamedStructuredOutput: nil,
            tools: [.init(name: "lookup", description: "lookup", inputSchema: .object([:]), supportsParallelExecution: parallel)],
            session: demoSession())
    }

    private func enqueueResponses(parallel: Bool) async {
        let calls = (0..<(parallel ? 2 : 1)).map {
            "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"function_call\",\"name\":\"lookup\",\"call_id\":\"call-\($0)\",\"arguments\":\"{}\"}}\n\n"
        }.joined()
        await TestURLProtocol.enqueue(.init(body: Data((calls + "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"first\"}}\n\n").utf8)))
        await TestURLProtocol.enqueue(.init(body: Data("data: {\"type\":\"response.completed\",\"response\":{\"id\":\"second\"}}\n\n".utf8), inspect: { request in
            let body = String(decoding: try XCTUnwrap(requestBodyData(for: request)), as: UTF8.self)
            XCTAssertFalse(body.contains("Duplicate"))
            if parallel { XCTAssertTrue(body.contains("Second valid")) }
        }))
    }
}

private struct ToolValidationSessionProvider: AgentSessionProviding {
    func currentSession() async -> ChatGPTSession? { demoSession() }
}
