import AssistantRuntimeKit
import XCTest

final class CodexResponsesBackendTests: XCTestCase {
    override func tearDown() {
        let expectation = XCTestExpectation(description: "reset protocol stubs")
        Task {
            await TestURLProtocol.reset()
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
        super.tearDown()
    }

    func testBackendStreamsAssistantMessageFromResponsesEndpoint() async throws {
        let backend = CodexResponsesBackend(urlSession: makeTestURLSession())
        let session = ChatGPTSession(
            accessToken: "access-token",
            refreshToken: "refresh-token",
            account: ChatGPTAccount(id: "workspace-123", email: "taylor@example.com", plan: .plus)
        )

        await TestURLProtocol.enqueue(
            .init(
                headers: ["Content-Type": "text/event-stream"],
                body: Data(
                    """
                    event: response.output_text.delta
                    data: {"type":"response.output_text.delta","delta":"Hello from "}

                    event: response.output_text.delta
                    data: {"type":"response.output_text.delta","delta":"Codex"}

                    event: response.output_item.done
                    data: {"type":"response.output_item.done","item":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Hello from Codex"}]}}

                    event: response.completed
                    data: {"type":"response.completed","response":{"id":"resp_1","usage":{"input_tokens":12,"input_tokens_details":{"cached_tokens":3},"output_tokens":4}}}

                    """.utf8
                ),
                inspect: { request in
                    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-token")
                    XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-ID"), "workspace-123")
                    XCTAssertEqual(request.value(forHTTPHeaderField: "originator"), "codex_cli_rs")
                }
            )
        )

        let turnStream = try await backend.beginTurn(
            thread: AssistantThread(id: "thread-1"),
            history: [],
            message: UserMessageRequest(text: "Hi there"),
            tools: [],
            session: session
        )

        var deltas: [String] = []
        var completedMessage: AssistantMessage?
        var summary: AssistantTurnSummary?

        for try await event in turnStream.events {
            switch event {
            case let .assistantMessageDelta(_, _, delta):
                deltas.append(delta)
            case let .assistantMessageCompleted(message):
                completedMessage = message
            case let .turnCompleted(turnSummary):
                summary = turnSummary
            default:
                break
            }
        }

        XCTAssertEqual(deltas.joined(), "Hello from Codex")
        XCTAssertEqual(completedMessage?.text, "Hello from Codex")
        XCTAssertEqual(summary?.usage?.inputTokens, 12)
        XCTAssertEqual(summary?.usage?.cachedInputTokens, 3)
        XCTAssertEqual(summary?.usage?.outputTokens, 4)
    }

    func testBackendContinuesTurnAfterToolOutput() async throws {
        let backend = CodexResponsesBackend(urlSession: makeTestURLSession())
        let session = ChatGPTSession(
            accessToken: "access-token",
            refreshToken: "refresh-token",
            account: ChatGPTAccount(id: "workspace-123", email: "taylor@example.com", plan: .plus)
        )

        let tool = ToolDefinition(
            name: "demo_lookup_profile",
            description: "Lookup a profile",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "name": .object(["type": .string("string")]),
                ]),
            ]),
            approvalPolicy: .requiresApproval
        )

        await TestURLProtocol.enqueue(
            .init(
                headers: ["Content-Type": "text/event-stream"],
                body: Data(
                    """
                    event: response.output_item.done
                    data: {"type":"response.output_item.done","item":{"type":"function_call","name":"demo_lookup_profile","arguments":"{\\"name\\":\\"Taylor\\"}","call_id":"call_1"}}

                    event: response.completed
                    data: {"type":"response.completed","response":{"id":"resp_1","usage":{"input_tokens":10,"input_tokens_details":{"cached_tokens":0},"output_tokens":1}}}

                    """.utf8
                ),
                inspect: { request in
                    let body = try XCTUnwrap(requestBodyData(for: request))
                    let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
                    let toolsJSON = json?["tools"] as? [[String: Any]]
                    XCTAssertEqual(toolsJSON?.first?["name"] as? String, "demo_lookup_profile")
                }
            )
        )

        await TestURLProtocol.enqueue(
            .init(
                headers: ["Content-Type": "text/event-stream"],
                body: Data(
                    """
                    event: response.output_text.delta
                    data: {"type":"response.output_text.delta","delta":"Profile ready"}

                    event: response.output_item.done
                    data: {"type":"response.output_item.done","item":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Profile ready"}]}}

                    event: response.completed
                    data: {"type":"response.completed","response":{"id":"resp_2","usage":{"input_tokens":6,"input_tokens_details":{"cached_tokens":1},"output_tokens":2}}}

                    """.utf8
                ),
                inspect: { request in
                    let body = try XCTUnwrap(requestBodyData(for: request))
                    let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
                    let input = try XCTUnwrap(json?["input"] as? [[String: Any]])
                    let functionOutput = try XCTUnwrap(
                        input.first(where: { $0["type"] as? String == "function_call_output" })
                    )
                    XCTAssertEqual(functionOutput["call_id"] as? String, "call_1")
                    XCTAssertEqual(functionOutput["output"] as? String, "profile[name=Taylor]")
                }
            )
        )

        let turnStream = try await backend.beginTurn(
            thread: AssistantThread(id: "thread-1"),
            history: [],
            message: UserMessageRequest(text: "Find the profile"),
            tools: [tool],
            session: session
        )

        var sawToolCall = false
        var finalAssistantMessage: AssistantMessage?

        for try await event in turnStream.events {
            switch event {
            case let .toolCallRequested(invocation):
                sawToolCall = true
                XCTAssertEqual(invocation.toolName, "demo_lookup_profile")
                try await turnStream.submitToolResult(
                    .success(invocation: invocation, text: "profile[name=Taylor]"),
                    for: invocation.id
                )
            case let .assistantMessageCompleted(message):
                finalAssistantMessage = message
            default:
                break
            }
        }

        XCTAssertTrue(sawToolCall)
        XCTAssertEqual(finalAssistantMessage?.text, "Profile ready")
    }
}
