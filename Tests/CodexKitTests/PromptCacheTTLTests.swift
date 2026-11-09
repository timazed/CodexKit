@testable import CodexKit
import XCTest

final class PromptCacheTTLTests: XCTestCase {
    override func setUp() async throws { await TestURLProtocol.reset() }
    override func tearDown() async throws { await TestURLProtocol.reset() }

    func testEachRequestOwnsItsCacheTTLAndLegacyRequestsDecodeWithoutOne() async throws {
        let backend = CodexResponsesBackend(urlSession: makeTestURLSession())
        for ttl: AgentPromptCacheTTL? in [.thirtyMinutes, .twelveHours, nil] {
            var request = Request(text: "Go")
            request.promptCacheTTL = ttl
            let restored = try JSONDecoder().decode(Request.self, from: JSONEncoder().encode(request))
            XCTAssertEqual(restored.promptCacheTTL, ttl)
            await TestURLProtocol.enqueue(.init(body: reply, inspect: { wire in
                try Self.assertTTL(ttl, in: wire)
            }))
            let stream = try await backend.beginTurn(thread: .init(id: "thread"), history: [], message: restored,
                instructions: "", responseFormat: nil, streamedStructuredOutput: nil, tools: [], session: demoSession())
            for try await _ in stream.events {}
        }
        XCTAssertNil(try JSONDecoder().decode(Request.self, from: Data(#"{"text":"old"}"#.utf8)).promptCacheTTL)
    }

    func testRecoveryPreparationFreezesTTLInExactRequestBytes() async throws {
        let backend = CodexResponsesBackend(urlSession: makeTestURLSession())
        let adapter = await backend.structuredRecoveryAdapter
        var request = Request(text: "Go", executionMode: .ephemeral)
        request.promptCacheTTL = .twelveHours
        let format = AgentStructuredOutputFormat(name: "value", rawSchema: .object([
            "type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(false)]))
        let prepared = try await adapter.prepare(thread: .init(id: "thread"), request: request,
            instructions: "", format: format, session: demoSession())
        let restored = try JSONDecoder().decode(AgentRecoveryPreparedRequest.self, from: JSONEncoder().encode(prepared))
        try restored.validate()
        let body = try JSONDecoder().decode(JSONValue.self, from: restored.body)
        XCTAssertEqual(body.objectValue?["prompt_cache_options"], .object(["ttl": .string("12h")]))
        XCTAssertEqual(restored.body, prepared.body)
    }

    func testAutomaticCompactionSharesTurnPreferenceAndNextTurnClearsIt() async throws {
        let runtime = try AgentRuntime(configuration: .init(sessionProvider: DesignReadOnlyProvider(),
            backend: CodexResponsesBackend(urlSession: makeTestURLSession()), approvalPresenter: AutoApprovalPresenter(),
            stateStore: InMemoryRuntimeStateStore(), contextCompaction: .init(isEnabled: true, strategy: .remoteOnly,
                trigger: .init(estimatedTokenThreshold: 1))))
        let thread = try await runtime.createThread()
        await TestURLProtocol.enqueue(.init(body: reply))
        _ = try await runtime.send(Request(text: "First input"), in: thread.id)
        for ttl: AgentPromptCacheTTL? in [.thirtyMinutes, nil] {
            await TestURLProtocol.enqueue(.init(body: streamedCompactionReply(), inspect: { try Self.assertTTL(ttl, in: $0) }))
            await TestURLProtocol.enqueue(.init(body: reply, inspect: { try Self.assertTTL(ttl, in: $0) }))
            var request = Request(text: "Next input")
            request.promptCacheTTL = ttl
            _ = try await runtime.send(request, in: thread.id)
        }
    }

    private static func assertTTL(_ ttl: AgentPromptCacheTTL?, in request: URLRequest) throws {
        let body = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(try requestBodyData(for: request)))
        XCTAssertEqual(body.objectValue?["prompt_cache_options"], ttl.map { .object(["ttl": .string($0.rawValue)]) })
    }

    func testTTLIsPreservedAcrossHTTPRetryAndHostToolRound() async throws {
        let backend = CodexResponsesBackend(configuration: .init(requestRetryPolicy:
            .init(maxAttempts: 2, initialBackoff: 0, maxBackoff: 0, jitterFactor: 0)), urlSession: makeTestURLSession())
        await TestURLProtocol.enqueue(.init(statusCode: 503, body: Data(), inspect: { try Self.assertTTL(.twelveHours, in: $0) }))
        await TestURLProtocol.enqueue(.init(body: Data("""
        data: {"type":"response.output_item.done","item":{"type":"function_call","name":"lookup","arguments":"{}","call_id":"call"}}

        data: {"type":"response.completed","response":{"id":"tool"}}

        """.utf8), inspect: { try Self.assertTTL(.twelveHours, in: $0) }))
        await TestURLProtocol.enqueue(.init(body: reply, inspect: { try Self.assertTTL(.twelveHours, in: $0) }))
        var request = Request(text: "Go")
        request.promptCacheTTL = .twelveHours
        let tool = ToolDefinition(name: "lookup", description: "Lookup", inputSchema: .object(["type": .string("object")]), approvalPolicy: .automatic)
        let stream = try await backend.beginTurn(thread: .init(id: "t"), history: [], message: request,
            instructions: "", responseFormat: nil, streamedStructuredOutput: nil, tools: [tool], session: demoSession())
        var toolCalls = 0
        for try await event in stream.events {
            if case let .toolRoundRequested(round) = event {
                let invocation = try XCTUnwrap(round.calls.first)
                toolCalls += 1
                try await stream.submitToolResult(.success(invocation: invocation, text: "result"), for: invocation.id)
            }
        }
        XCTAssertEqual(toolCalls, 1)
    }

    func testConcurrentCompactionsKeepIndependentTaskLocalPreferences() async throws {
        let backend = CodexResponsesBackend(urlSession: makeTestURLSession())
        for _ in 0..<2 {
            await TestURLProtocol.enqueue(.init(body: streamedCompactionReply(), inspect: { wire in
                let body = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(try requestBodyData(for: wire)))
                let id = body.objectValue?["prompt_cache_key"]?.stringValue
                try Self.assertTTL(id == "30m" ? .thirtyMinutes : .twelveHours, in: wire)
            }))
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for ttl in [AgentPromptCacheTTL.thirtyMinutes, .twelveHours] {
                group.addTask {
                    try await AgentPromptCacheContext.$current.withValue(ttl) {
                        await Task.yield()
                        _ = try await backend.compactContext(thread: .init(id: ttl.rawValue),
                            effectiveHistory: [.init(threadID: ttl.rawValue, role: .user, text: "Compact")],
                            providerContext: nil, instructions: "", tools: [], session: demoSession())
                    }
                }
            }
            try await group.waitForAll()
        }
        XCTAssertNil(AgentPromptCacheContext.current)
    }

    private var reply: Data { Data("""
    data: {"type":"response.output_item.done","item":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Done"}]}}

    data: {"type":"response.completed","response":{"id":"done"}}

    """.utf8) }
}
