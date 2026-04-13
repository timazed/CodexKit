import CodexKit
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
                    let body = try XCTUnwrap(requestBodyData(for: request))
                    let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
                    let reasoning = try XCTUnwrap(json?["reasoning"] as? [String: Any])
                    XCTAssertEqual(reasoning["effort"] as? String, "medium")
                }
            )
        )

        let turnStream = try await backend.beginTurn(
            thread: AgentThread(id: "thread-1"),
            history: [],
            message: UserMessageRequest(text: "Hi there"),
            instructions: "Resolved instructions",
            responseFormat: nil,
            streamedStructuredOutput: nil,
            tools: [],
            session: session
        )

        var deltas: [String] = []
        var completedMessage: AgentMessage?
        var summary: AgentTurnSummary?

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

    func testBackendEncodesConfiguredReasoningEffort() async throws {
        let backend = CodexResponsesBackend(
            configuration: CodexResponsesBackendConfiguration(
                model: "gpt-5.4",
                reasoningEffort: .extraHigh
            ),
            urlSession: makeTestURLSession()
        )
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
                    event: response.output_item.done
                    data: {"type":"response.output_item.done","item":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Ready"}]}}

                    event: response.completed
                    data: {"type":"response.completed","response":{"id":"resp_effort","usage":{"input_tokens":4,"input_tokens_details":{"cached_tokens":0},"output_tokens":1}}}

                    """.utf8
                ),
                inspect: { request in
                    let body = try XCTUnwrap(requestBodyData(for: request))
                    let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
                    let reasoning = try XCTUnwrap(json?["reasoning"] as? [String: Any])
                    XCTAssertEqual(reasoning["effort"] as? String, "xhigh")
                }
            )
        )

        let turnStream = try await backend.beginTurn(
            thread: AgentThread(id: "thread-effort"),
            history: [],
            message: UserMessageRequest(text: "Think hard"),
            instructions: "Resolved instructions",
            responseFormat: nil,
            streamedStructuredOutput: nil,
            tools: [],
            session: session
        )

        for try await _ in turnStream.events {}
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
                    XCTAssertEqual(json?["instructions"] as? String, "Resolved instructions")
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
            thread: AgentThread(id: "thread-1"),
            history: [],
            message: UserMessageRequest(text: "Find the profile"),
            instructions: "Resolved instructions",
            responseFormat: nil,
            streamedStructuredOutput: nil,
            tools: [tool],
            session: session
        )

        var sawToolCall = false
        var finalAssistantMessage: AgentMessage?

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

    func testBackendIncludesWebSearchToolWhenEnabled() async throws {
        let backend = CodexResponsesBackend(
            configuration: CodexResponsesBackendConfiguration(enableWebSearch: true),
            urlSession: makeTestURLSession()
        )
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
                    event: response.output_item.done
                    data: {"type":"response.output_item.done","item":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Search ready"}]}}

                    event: response.completed
                    data: {"type":"response.completed","response":{"id":"resp_search","usage":{"input_tokens":5,"input_tokens_details":{"cached_tokens":0},"output_tokens":2}}}

                    """.utf8
                ),
                inspect: { request in
                    let body = try XCTUnwrap(requestBodyData(for: request))
                    let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
                    let toolsJSON = try XCTUnwrap(json?["tools"] as? [[String: Any]])
                    XCTAssertTrue(
                        toolsJSON.contains(where: { $0["type"] as? String == "web_search" })
                    )
                }
            )
        )

        let turnStream = try await backend.beginTurn(
            thread: AgentThread(id: "thread-search"),
            history: [],
            message: UserMessageRequest(text: "Search the web"),
            instructions: "Resolved instructions",
            responseFormat: nil,
            streamedStructuredOutput: nil,
            tools: [],
            session: session
        )

        for try await _ in turnStream.events {}
    }

    func testBackendEncodesUserImageAttachmentsAsInputImages() async throws {
        let backend = CodexResponsesBackend(urlSession: makeTestURLSession())
        let session = ChatGPTSession(
            accessToken: "access-token",
            refreshToken: "refresh-token",
            account: ChatGPTAccount(id: "workspace-123", email: "taylor@example.com", plan: .plus)
        )
        let image = AgentImageAttachment.png(Data([0x89, 0x50, 0x4E, 0x47]))

        await TestURLProtocol.enqueue(
            .init(
                headers: ["Content-Type": "text/event-stream"],
                body: Data(
                    """
                    event: response.output_item.done
                    data: {"type":"response.output_item.done","item":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Image received"}]}}

                    event: response.completed
                    data: {"type":"response.completed","response":{"id":"resp_image","usage":{"input_tokens":5,"input_tokens_details":{"cached_tokens":0},"output_tokens":2}}}

                    """.utf8
                ),
                inspect: { request in
                    let body = try XCTUnwrap(requestBodyData(for: request))
                    let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
                    let input = try XCTUnwrap(json?["input"] as? [[String: Any]])
                    let message = try XCTUnwrap(
                        input.first(where: { $0["type"] as? String == "message" })
                    )
                    let content = try XCTUnwrap(message["content"] as? [[String: Any]])
                    XCTAssertTrue(
                        content.contains(where: {
                            ($0["type"] as? String) == "input_text" &&
                                ($0["text"] as? String) == "Describe this image"
                        })
                    )
                    XCTAssertTrue(
                        content.contains(where: {
                            ($0["type"] as? String) == "input_image" &&
                                ($0["image_url"] as? String)?.hasPrefix("data:image/png;base64,") == true
                        })
                    )
                }
            )
        )

        let turnStream = try await backend.beginTurn(
            thread: AgentThread(id: "thread-image"),
            history: [],
            message: UserMessageRequest(
                text: "Describe this image",
                images: [image]
            ),
            instructions: "Resolved instructions",
            responseFormat: nil,
            streamedStructuredOutput: nil,
            tools: [],
            session: session
        )

        for try await _ in turnStream.events {}
    }

    func testBackendCarriesToolImageOutputsIntoAssistantMessages() async throws {
        let backend = CodexResponsesBackend(urlSession: makeTestURLSession())
        let session = ChatGPTSession(
            accessToken: "access-token",
            refreshToken: "refresh-token",
            account: ChatGPTAccount(id: "workspace-123", email: "taylor@example.com", plan: .plus)
        )
        let tool = ToolDefinition(
            name: "generate_image",
            description: "Generates an image and returns a URL",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "prompt": .object(["type": .string("string")]),
                ]),
            ]),
            approvalPolicy: .automatic
        )
        let pngBytes = Data([0x89, 0x50, 0x4E, 0x47])
        let imageURL = try XCTUnwrap(
            URL(string: "data:image/png;base64,\(pngBytes.base64EncodedString())")
        )

        await TestURLProtocol.enqueue(
            .init(
                headers: ["Content-Type": "text/event-stream"],
                body: Data(
                    """
                    event: response.output_item.done
                    data: {"type":"response.output_item.done","item":{"type":"function_call","name":"generate_image","arguments":"{\\"prompt\\":\\"sunset\\"}","call_id":"call_img_1"}}

                    event: response.completed
                    data: {"type":"response.completed","response":{"id":"resp_tool_1","usage":{"input_tokens":8,"input_tokens_details":{"cached_tokens":0},"output_tokens":2}}}

                    """.utf8
                )
            )
        )

        await TestURLProtocol.enqueue(
            .init(
                headers: ["Content-Type": "text/event-stream"],
                body: Data(
                    """
                    event: response.output_item.done
                    data: {"type":"response.output_item.done","item":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Here you go"}]}}

                    event: response.completed
                    data: {"type":"response.completed","response":{"id":"resp_tool_2","usage":{"input_tokens":4,"input_tokens_details":{"cached_tokens":0},"output_tokens":1}}}

                    """.utf8
                ),
                inspect: { request in
                    let body = try XCTUnwrap(requestBodyData(for: request))
                    let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
                    let input = try XCTUnwrap(json?["input"] as? [[String: Any]])
                    let functionOutput = try XCTUnwrap(
                        input.first(where: { $0["type"] as? String == "function_call_output" })
                    )
                    let output = try XCTUnwrap(functionOutput["output"] as? String)
                    XCTAssertTrue(output.contains("Generated image ready"))
                    XCTAssertTrue(output.contains("Image URLs:"))
                    XCTAssertTrue(output.contains(imageURL.absoluteString))
                }
            )
        )

        let turnStream = try await backend.beginTurn(
            thread: AgentThread(id: "thread-tool-image"),
            history: [],
            message: UserMessageRequest(text: "Make me an image"),
            instructions: "Resolved instructions",
            responseFormat: nil,
            streamedStructuredOutput: nil,
            tools: [tool],
            session: session
        )

        var assistantMessage: AgentMessage?

        for try await event in turnStream.events {
            switch event {
            case let .toolCallRequested(invocation):
                let result = ToolResultEnvelope(
                    invocationID: invocation.id,
                    toolName: invocation.toolName,
                    success: true,
                    content: [
                        .text("Generated image ready"),
                        .image(imageURL),
                    ]
                )
                try await turnStream.submitToolResult(result, for: invocation.id)

            case let .assistantMessageCompleted(message):
                assistantMessage = message

            default:
                break
            }
        }

        XCTAssertEqual(assistantMessage?.text, "Here you go")
        XCTAssertEqual(assistantMessage?.images.count, 1)
        XCTAssertEqual(assistantMessage?.images.first?.mimeType, "image/png")
        XCTAssertEqual(assistantMessage?.images.first?.data, pngBytes)
    }

    func testBackendSendsStructuredInputAsSeparateDeveloperContextBlock() async throws {
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
                    event: response.output_item.done
                    data: {"type":"response.output_item.done","item":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Done"}]}}

                    event: response.completed
                    data: {"type":"response.completed","response":{"id":"resp_structured_input","usage":{"input_tokens":8,"input_tokens_details":{"cached_tokens":0},"output_tokens":1}}}

                    """.utf8
                ),
                inspect: { request in
                    let body = try XCTUnwrap(requestBodyData(for: request))
                    let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
                    let input = try XCTUnwrap(json?["input"] as? [[String: Any]])

                    let developerMessage = try XCTUnwrap(
                        input.first(where: { $0["role"] as? String == "developer" })
                    )
                    let developerContent = try XCTUnwrap(developerMessage["content"] as? [[String: Any]])
                    let developerText = try XCTUnwrap(developerContent.first?["text"] as? String)
                    XCTAssertTrue(developerText.contains("Authoritative structured context"))
                    XCTAssertTrue(developerText.contains("<codexkit-structured-input name=\"PlannerContext\">"))
                    XCTAssertTrue(developerText.contains("\"objective\""))
                    XCTAssertTrue(developerText.contains("\"customerTier\""))
                    XCTAssertTrue(developerText.contains("<codexkit-structured-input name=\"browser_snapshot\">"))

                    let userMessage = try XCTUnwrap(
                        input.first(where: { $0["role"] as? String == "user" })
                    )
                    let userContent = try XCTUnwrap(userMessage["content"] as? [[String: Any]])
                    XCTAssertEqual(userContent.count, 1)
                    XCTAssertEqual(userContent.first?["text"] as? String, "Answer using the provided context.")
                }
            )
        )

        let turnStream = try await backend.beginTurn(
            thread: AgentThread(id: "thread-structured-input"),
            history: [],
            message: UserMessageRequest(
                text: "Answer using the provided context.",
                structuredInput: AgentStructuredInput(
                    schemaName: "PlannerContext",
                    payload: .object([
                        "objective": .string("Resolve shipping issue"),
                        "customerTier": .string("plus"),
                    ])
                ),
                structuredSections: [
                    AgentStructuredSection(
                        name: "browser_snapshot",
                        schemaName: "BrowserSnapshot",
                        payload: .object([
                            "pageTitle": .string("Order #1234"),
                            "status": .string("In transit"),
                        ])
                    ),
                ]
            ),
            instructions: "Resolved instructions",
            responseFormat: nil,
            streamedStructuredOutput: nil,
            tools: [],
            session: session
        )

        for try await _ in turnStream.events {}
    }

}
