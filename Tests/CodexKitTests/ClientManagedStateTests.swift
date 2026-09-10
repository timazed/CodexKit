@testable import CodexKit
import XCTest

final class ClientManagedStateTests: XCTestCase {
    func testOnlyClientManagedModeCanBeConfiguredOrDecoded() throws {
        XCTAssertEqual(CodexResponsesBackendConfiguration().stateManagement, .clientManaged)
        XCTAssertEqual(CodexResponsesBackendConfiguration(model: .gpt56Sol, stateManagement: .clientManaged).stateManagement,
            .clientManaged)
        XCTAssertNil(CodexResponsesStateManagement(rawValue: "serverManaged"))
        XCTAssertThrowsError(try JSONDecoder().decode(CodexResponsesStateManagement.self, from: Data(#""serverManaged""#.utf8)))
        XCTAssertEqual(try JSONDecoder().decode(CodexResponsesStateManagement.self, from: Data(#""clientManaged""#.utf8)),
            .clientManaged)
    }

    func testLegacyServerOnlyContextFailsBeforeGenerationOrCompactionHTTP() async throws {
        RecoveryProbeURLProtocol.configure([])
        let backend = CodexResponsesBackend(urlSession: RecoveryProbeURLProtocol.session())
        let context = AgentProviderContext(providerID: "openai.responses", payload: .object([
            "items": .array([]), "previous_response_id": .string("legacy-response")
        ]))
        let stream = try await backend.beginTurn(thread: .init(id: "thread"), history: [], providerContext: context,
            message: Request(text: "Continue"), instructions: "", responseFormat: nil,
            streamedStructuredOutput: nil, tools: [], session: demoSession())
        do {
            for try await _ in stream.events {}
            XCTFail("Server-only context must not silently become an empty client context")
        } catch { XCTAssertEqual((error as? AgentRuntimeError)?.code, "responses_server_state_unsupported") }
        do {
            _ = try await backend.compactContext(thread: .init(id: "thread"), effectiveHistory: [], providerContext: context,
                instructions: "", tools: [], session: demoSession())
            XCTFail("Compaction requires local input")
        } catch { XCTAssertEqual((error as? AgentRuntimeError)?.code, "responses_server_state_unsupported") }
        XCTAssertTrue(RecoveryProbeURLProtocol.requests.isEmpty)
    }

    func testLegacyIDWithLocalItemsIsNotTransmittedOrRetained() async throws {
        RecoveryProbeURLProtocol.configure([.init(body: "data: {\"type\":\"response.completed\",\"response\":{}}\n\n")])
        let backend = CodexResponsesBackend(urlSession: RecoveryProbeURLProtocol.session())
        let item: JSONValue = .object(["type": .string("reasoning"), "encrypted_content": .string("retained")])
        let context = AgentProviderContext(providerID: "openai.responses", payload: .object([
            "items": .array([item]), "previous_response_id": .string("legacy-response")
        ]))
        let stream = try await backend.beginTurn(thread: .init(id: "thread"), history: [], providerContext: context,
            message: Request(text: "Continue"), instructions: "", responseFormat: nil,
            streamedStructuredOutput: nil, tools: [], session: demoSession())
        var updated: AgentProviderContext?
        for try await event in stream.events {
            if case let .providerContextUpdated(_, context) = event { updated = context }
        }
        let requests = RecoveryProbeURLProtocol.requests
        XCTAssertEqual(requests.count, 1)
        let body = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(requests.first?.httpBody))
        XCTAssertEqual(body.objectValue?["store"], .bool(false))
        XCTAssertNil(body.objectValue?["previous_response_id"])
        XCTAssertEqual(body.objectValue?["input"]?.arrayValue?.first, item)
        XCTAssertNil(try XCTUnwrap(updated).payload.objectValue?["previous_response_id"]?.stringValue)
    }
}
