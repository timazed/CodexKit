import CodexKit
import XCTest

extension CodexResponsesBackendTests {
    func testBackendEncodesStructuredOutputFormat() async throws {
        let backend = CodexResponsesBackend(urlSession: makeTestURLSession())
        let session = ChatGPTSession(accessToken: "access-token", refreshToken: "refresh-token", account: ChatGPTAccount(id: "workspace-123", email: "taylor@example.com", plan: .plus))
        let responseFormat = AgentStructuredOutputFormat(name: "shipping_reply_draft", description: "A concise shipping support reply draft.", schema: .object(properties: ["reply": .string()], required: ["reply"], additionalProperties: false))

        await TestURLProtocol.enqueue(.init(headers: ["Content-Type": "text/event-stream"], body: Data("""
        event: response.output_item.done
        data: {"type":"response.output_item.done","item":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"{\\"reply\\":\\"Done\\"}"}]}}

        event: response.completed
        data: {"type":"response.completed","response":{"id":"resp_structured","usage":{"input_tokens":4,"input_tokens_details":{"cached_tokens":0},"output_tokens":1}}}

        """.utf8), inspect: { request in
            let body = try XCTUnwrap(requestBodyData(for: request))
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            let text = try XCTUnwrap(json?["text"] as? [String: Any])
            let format = try XCTUnwrap(text["format"] as? [String: Any])
            XCTAssertEqual(format["type"] as? String, "json_schema")
            XCTAssertEqual(format["name"] as? String, "shipping_reply_draft")
            XCTAssertEqual(format["description"] as? String, "A concise shipping support reply draft.")
            XCTAssertEqual(format["strict"] as? Bool, true)
            let schema = try XCTUnwrap(format["schema"] as? [String: Any])
            XCTAssertEqual(schema["type"] as? String, "object")
        }))

        let turnStream = try await backend.beginTurn(thread: AgentThread(id: "thread-structured"), history: [], message: UserMessageRequest(text: "Draft a reply."), instructions: "Resolved instructions", responseFormat: responseFormat, streamedStructuredOutput: nil, tools: [], session: session)
        for try await _ in turnStream.events {}
    }

    func testBackendStripsStructuredStreamFramingFromVisibleAssistantText() async throws {
        let backend = CodexResponsesBackend(urlSession: makeTestURLSession())
        let session = ChatGPTSession(accessToken: "access-token", refreshToken: "refresh-token", account: ChatGPTAccount(id: "workspace-123", email: "taylor@example.com", plan: .plus))
        let streamedStructuredOutput = AgentStreamedStructuredOutputRequest(
            responseFormat: AgentStructuredOutputFormat(
                name: "shipping_reply_draft",
                description: "A concise shipping support reply draft.",
                schema: .object(properties: ["reply": .string(), "priority": .string()], required: ["reply", "priority"], additionalProperties: false)
            ),
            options: .init(required: true)
        )

        await TestURLProtocol.enqueue(.init(headers: ["Content-Type": "text/event-stream"], body: Data("""
        event: response.output_text.delta
        data: {"type":"response.output_text.delta","delta":"Hello "}

        event: response.output_text.delta
        data: {"type":"response.output_text.delta","delta":"<codexkit-structured-output>{\\"reply\\":\\"Done\\",\\"priority\\":\\"high\\"}</codexkit-structured-output>"}

        event: response.output_item.done
        data: {"type":"response.output_item.done","item":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Hello <codexkit-structured-output>{\\"reply\\":\\"Done\\",\\"priority\\":\\"high\\"}</codexkit-structured-output>"}]}}

        event: response.completed
        data: {"type":"response.completed","response":{"id":"resp_streamed","usage":{"input_tokens":4,"input_tokens_details":{"cached_tokens":0},"output_tokens":1}}}

        """.utf8), inspect: { request in
            let body = try XCTUnwrap(requestBodyData(for: request))
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            let instructions = try XCTUnwrap(json?["instructions"] as? String)
            XCTAssertTrue(instructions.contains("CodexKit private streaming contract"))
            let text = json?["text"] as? [String: Any]
            let format = try XCTUnwrap(text?["format"] as? [String: Any])
            XCTAssertEqual(format["type"] as? String, "text")
        }))

        let turnStream = try await backend.beginTurn(thread: AgentThread(id: "thread-streamed-structured"), history: [], message: UserMessageRequest(text: "Draft a reply."), instructions: "Resolved instructions", responseFormat: nil, streamedStructuredOutput: streamedStructuredOutput, tools: [], session: session)

        var deltas: [String] = []
        var finalAssistantMessage: AgentMessage?
        var committedValue: JSONValue?

        for try await event in turnStream.events {
            switch event {
            case let .assistantMessageDelta(_, _, delta):
                deltas.append(delta)
            case let .assistantMessageCompleted(message):
                finalAssistantMessage = message
            case let .structuredOutputCommitted(value):
                committedValue = value
            default:
                break
            }
        }

        XCTAssertEqual(deltas.joined(), "Hello ")
        XCTAssertEqual(finalAssistantMessage?.text, "Hello")
        XCTAssertEqual(committedValue, .object(["reply": .string("Done"), "priority": .string("high")]))
    }
}
