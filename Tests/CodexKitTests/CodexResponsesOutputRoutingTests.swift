@testable import CodexKit
import XCTest

final class CodexResponsesOutputRoutingTests: XCTestCase {
    override func setUp() async throws { await TestURLProtocol.reset() }
    override func tearDown() async throws { await TestURLProtocol.reset() }

    func testNativeJSONRequestRetainsSchemaAndIdentifiedRawDeltas() async throws {
        let raw = #"{"id":9007199254740993,"text":" ok "}"# + "\n"
        await TestURLProtocol.enqueue(.init(body: try streamBody(raw: raw), inspect: { request in
            let body = try XCTUnwrap(requestBodyData(for: request))
            let value = try JSONDecoder().decode(JSONValue.self, from: body)
            XCTAssertEqual(value.objectValue?["text"]?.objectValue?["format"]?.objectValue?["type"], .string("json_schema"))
        }))
        let runtime = try runtime()
        let thread = try await runtime.createThread()
        let format = AgentJSONResponseFormat<AgentOutputDecoderTests.Record>(name: "record", schema: .object(
            properties: ["id": .integer, "text": .string()], required: ["id", "text"]))
        var previews = "", committed = false
        for try await event in try await runtime.stream(Request(text: "Go"), in: thread.id, output: format) {
            if case let .format(context, .rawJSONDelta(text)) = event {
                XCTAssertEqual(context.messageID, "item"); previews += text
            }
            if case let .outputCommitted(_, value) = event { XCTAssertEqual(value.id, 9_007_199_254_740_993); committed = true }
        }
        XCTAssertEqual(previews, raw); XCTAssertTrue(committed)
    }

    func testXMLUsesTextModePreservesWhitespaceAndSeparatesCommentary() async throws {
        let raw = " \n<r>ok</r>\n"
        let commentary = "data: {\"type\":\"response.output_item.added\",\"item\":{\"id\":\"note\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[],\"phase\":\"commentary\"}}\n\n"
            + "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"note\",\"content_index\":0,\"delta\":\"Working\"}\n\n"
            + "data: {\"type\":\"response.output_item.done\",\"item\":{\"id\":\"note\",\"type\":\"message\",\"role\":\"assistant\",\"phase\":\"commentary\",\"content\":[{\"type\":\"output_text\",\"text\":\"Working\"}]}}\n\n"
        await TestURLProtocol.enqueue(.init(body: Data(commentary.utf8) + (try streamBody(raw: raw)), inspect: { request in
            let value = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(requestBodyData(for: request)))
            XCTAssertNotEqual(value.objectValue?["text"]?.objectValue?["format"]?.objectValue?["type"], .string("json_schema"))
        }))
        let runtime = try runtime()
        let thread = try await runtime.createThread()
        let result = try await runtime.send(Request(text: "Go"), in: thread.id,
            output: AgentXMLResponseFormat(name: "r", schema: .element("r", text: .string)))
        XCTAssertEqual(result.rawXML, raw)
        XCTAssertEqual(result.root.text, "ok")
    }

    func testRefusalAndMidStreamTransportFailureNeverCommit() async throws {
        for refusal in [true, false] {
            let body = refusal
                ? Data("data: {\"type\":\"response.output_item.done\",\"item\":{\"id\":\"item\",\"type\":\"message\",\"role\":\"assistant\",\"phase\":\"final_answer\",\"content\":[{\"type\":\"refusal\",\"refusal\":\"Cannot comply\"}]}}\n\n".utf8)
                : try streamBody(raw: "<r>ok</r>", includeCompletion: false)
            await TestURLProtocol.enqueue(.init(body: body))
            let runtime = try runtime()
            let thread = try await runtime.createThread()
            do {
                _ = try await runtime.send(Request(text: "Go"), in: thread.id,
                    output: AgentXMLResponseFormat(name: "r", schema: .element("r", text: .string)))
                XCTFail("Failed provider output committed")
            } catch {}
            let latest = try await runtime.fetchLatestStructuredOutputMetadata(id: thread.id)
            XCTAssertNil(latest)
        }
    }

    private func runtime() throws -> AgentRuntime {
        try AgentRuntime(configuration: .init(sessionProvider: DesignReadOnlyProvider(),
            backend: CodexResponsesBackend(configuration: .init(enableWebSearch: false, enableImageGeneration: false,
                requestRetryPolicy: .disabled), urlSession: makeTestURLSession()),
            approvalPresenter: AutoApprovalPresenter(), stateStore: InMemoryRuntimeStateStore()))
    }
    private func streamBody(raw: String, includeCompletion: Bool = true) throws -> Data {
        let quoted = String(decoding: try JSONEncoder().encode(raw), as: UTF8.self)
        var text = """
        data: {"type":"response.output_item.added","item":{"id":"item","type":"message","role":"assistant","content":[],"phase":"final_answer"}}

        data: {"type":"response.output_text.delta","item_id":"item","content_index":0,"delta":\(quoted)}

        data: {"type":"response.output_item.done","item":{"id":"item","type":"message","role":"assistant","phase":"final_answer","content":[{"type":"output_text","text":\(quoted)}]}}


        """
        if includeCompletion { text += "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"response\",\"usage\":{\"input_tokens\":1,\"output_tokens\":2}}}\n\n" }
        return Data(text.utf8)
    }
}
