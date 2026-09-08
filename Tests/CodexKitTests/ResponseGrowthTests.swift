@testable import CodexKit
import XCTest

final class ResponseGrowthTests: XCTestCase {
    override func setUp() async throws { await TestURLProtocol.reset() }
    override func tearDown() async throws { await TestURLProtocol.reset() }

    func testSlowConsumerReceivesEveryDeltaThroughAllThreeQueuesAtCapacityOne() async throws {
        let deltas = (0..<200).map { "\($0)🙂 " }
        var body = try deltas.map { try sse(["type": "response.output_text.delta", "delta": $0]) }.joined()
        body += try sse(["type": "response.output_item.done", "item": ["type": "message", "id": "assistant",
            "role": "assistant", "content": [["type": "output_text", "text": deltas.joined()]]]])
        body += try sse(["type": "response.completed", "response": ["id": "response"]])
        await TestURLProtocol.enqueue(.init(body: Data(body.utf8)))
        let secure = KeychainSessionSecureStore(service: "CodexKit.ResponseGrowthTests", account: UUID().uuidString)
        defer { try? secure.deleteSession() }
        let runtime = try AgentRuntime(configuration: .init(authProvider: DemoChatGPTAuthProvider(), secureStore: secure,
            backend: CodexResponsesBackend(configuration: .init(maximumBufferedEvents: 1), urlSession: makeTestURLSession()),
            approvalPresenter: AutoApprovalPresenter(), stateStore: InMemoryRuntimeStateStore(), maximumBufferedEvents: 1))
        _ = try await runtime.useSession(demoSession())
        let thread = try await runtime.createThread()
        let stream = try await runtime.stream(Request(text: "Go"), in: thread.id)
        try await Task.sleep(for: .milliseconds(30))
        var received: [String] = []
        var committed: [AgentMessage] = []
        var completions = 0
        for try await event in stream {
            switch event {
            case let .assistantMessageDelta(_, _, delta): received.append(delta)
            case let .messageCommitted(message): committed.append(message)
            case .turnCompleted: completions += 1
            default: break
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(received, deltas)
        XCTAssertEqual(committed.map(\.role), [.user, .assistant])
        XCTAssertEqual(committed.last?.text, deltas.joined().trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertEqual(completions, 1)
        let active = await runtime.activeTurnID(in: thread.id)
        XCTAssertNil(active)
    }

    func testResponseByteBudgetIsSharedAcrossModelPasses() async throws {
        let tool = try sse(["type": "response.output_item.done", "item": ["type": "function_call",
            "name": "lookup", "call_id": "call", "arguments": "{}"]])
        let first = tool + (try sse(["type": "response.completed", "response": ["id": "first"]]))
        let second = try sse(["type": "response.output_text.delta", "delta": String(repeating: "x", count: 100)])
            + sse(["type": "response.completed", "response": ["id": "second"]])
        let requests = ResponseRequestCounter()
        for body in [first, second] {
            await TestURLProtocol.enqueue(.init(body: Data(body.utf8), inspect: { _ in requests.record() }))
        }
        let backend = CodexResponsesBackend(configuration: .init(maximumBufferedEvents: 1,
            maximumResponseBytes: max(first.utf8.count, second.utf8.count)), urlSession: makeTestURLSession())
        let stream = try await begin(backend)
        do {
            for try await event in stream.events {
                if case let .toolCallRequested(invocation) = event {
                    try await stream.submitToolResult(.success(invocation: invocation, text: "Done"), for: invocation.id)
                }
            }
            XCTFail("Expected the response-byte budget to fail")
        } catch { XCTAssertEqual((error as? AgentRuntimeError)?.executionLimit, .responseBytes) }
        XCTAssertEqual(requests.count, 2)
    }

    func testRetriesCannotResetTheResponseByteBudget() async throws {
        let body = try sse(["type": "response.created", "response": ["id": String(repeating: "x", count: 100)]])
        let requests = ResponseRequestCounter()
        for _ in 0..<2 {
            await TestURLProtocol.enqueue(.init(body: Data(body.utf8), inspect: { _ in requests.record() }))
        }
        let backend = CodexResponsesBackend(configuration: .init(
            requestRetryPolicy: .init(maxAttempts: 3, initialBackoff: 0, jitterFactor: 0),
            maximumBufferedEvents: 1, maximumResponseBytes: body.utf8.count), urlSession: makeTestURLSession())
        do {
            for try await _ in try await begin(backend).events {}
            XCTFail("Expected the retry to exhaust the shared byte budget")
        } catch { XCTAssertEqual((error as? AgentRuntimeError)?.executionLimit, .responseBytes) }
        XCTAssertEqual(requests.count, 2, "A budget error must not be retried")
    }

    func testIncompleteResponseCannotAccumulateUnlimitedProviderItems() async throws {
        let item = try sse(["type": "response.output_item.done", "item": ["type": "unknown_item"]])
        await TestURLProtocol.enqueue(.init(body: Data(String(repeating: item,
            count: AgentStoreLimits.maximumResponseItemCount + 1).utf8)))
        let backend = CodexResponsesBackend(configuration: .init(maximumBufferedEvents: 1, maximumResponseBytes: nil),
            urlSession: makeTestURLSession())
        do {
            for try await _ in try await begin(backend).events {}
            XCTFail("Expected the response-item limit to fail before EOF")
        } catch { XCTAssertEqual((error as? AgentRuntimeError)?.executionLimit, .responseItems) }
    }

    func testFullSteeringQueueRejectsNewInputAndPreservesAcceptedOrder() async throws {
        let control = CodexTurnControl()
        let messages = (0..<AgentStoreLimits.maximumPendingSteeringMessageCount).map {
            AgentMessage(threadID: "thread", role: .user, text: "Input \($0)")
        }
        for message in messages { try await control.steer(message) }
        do {
            try await control.steer(.init(threadID: "thread", role: .user, text: "Overflow"))
            XCTFail("Expected queue saturation to fail")
        } catch { XCTAssertEqual((error as? AgentRuntimeError)?.code, "steering_queue_full") }
        let drained = await control.drain(closeIfEmpty: false)
        XCTAssertEqual(drained, messages)
        try await control.steer(messages[0])
        let afterDrain = await control.drain(closeIfEmpty: false)
        XCTAssertEqual(afterDrain, [messages[0]])
    }

    private func sse(_ value: [String: Any]) throws -> String {
        "data: " + String(decoding: try JSONSerialization.data(withJSONObject: value, options: .sortedKeys), as: UTF8.self) + "\n\n"
    }

    private func begin(_ backend: CodexResponsesBackend) async throws -> AgentTurnStream {
        try await backend.beginTurn(thread: .init(id: "thread"), history: [], message: Request(text: "Go"),
            instructions: "", responseFormat: nil, streamedStructuredOutput: nil,
            tools: [.init(name: "lookup", description: "lookup", inputSchema: .object([:]))], session: demoSession())
    }
}

private final class ResponseRequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func record() { lock.withLock { value += 1 } }
}
