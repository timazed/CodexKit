@testable import CodexKit
import XCTest

final class AgentSafetyRecourseTests: XCTestCase {
    private func metadata(domain: String = "cyber", topic: String = "risky_cybersecurity_activities",
                          version: Int = 1, firstPrompt: String = "Explain defensive security") throws -> CodexResponsesStreamEvent {
        let object: [String: Any] = ["type": "response.metadata", "sequence_number": 1,
            "metadata": ["openai_chatgpt_moderation_metadata": ["safety_recourse": [
                "schema_version": version, "domain": domain, "source": "user_request",
                "source_message": ["id": "private-message-id", "kind": "ordinary_message", "role": "user"],
                "topic": topic, "suggestions": [
                    ["label": "Overview", "prompt_text": firstPrompt],
                    ["label": "Recovery", "prompt_text": "Explain account recovery"],
                    ["label": "Prevention", "prompt_text": "Explain prevention"]]]]]]
        return try JSONDecoder().decode(CodexResponsesEventPayload.self,
            from: JSONSerialization.data(withJSONObject: object)).event
    }

    private func failure(_ code: String = "cyber_policy", sequence: Int = 2) -> CodexResponsesStreamEvent {
        .init(kind: .failed(.init(code: .responsesStreamFailed, message: "Blocked",
            http: .init(statusCode: 200, providerCode: code)), responseID: "response-1"), sequenceNumber: sequence)
    }

    private func error(_ event: CodexResponsesStreamEvent) throws -> AgentRuntimeError {
        guard case let .failed(error, _) = event.kind else { throw NSError(domain: "test", code: 1) }
        return error
    }

    func testMatchingPolicyRetainsGuidanceAcrossErrorWrappingAndCoding() throws {
        for (domain, topic) in [("cyber", "risky_cybersecurity_activities"), ("bio", "risky_biological_activities")] {
            var state = CodexSafetyRecourseState()
            _ = state.consume(try metadata(domain: domain, topic: topic))
            let original = try error(state.consume(failure("\(domain)_policy")))
            let wrapped = ResponsesAttemptObservation().failure(original, clientRequestID: "client", requestID: "request")
            XCTAssertEqual(wrapped.safetyRecourse?.domain.rawValue, domain)
            XCTAssertEqual(wrapped.safetyRecourse?.suggestions.count, 3)
            let bytes = try JSONEncoder().encode(wrapped)
            XCTAssertEqual(try JSONDecoder().decode(AgentRuntimeError.self, from: bytes), wrapped)
            XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("private-message-id"))
            XCTAssertNil(try error(state.consume(failure(sequence: 3))).safetyRecourse)
        }
    }

    func testInvalidUnknownAndMismatchedMetadataDoesNotReplaceErrors() throws {
        for event in [try metadata(version: 2), try metadata(topic: "unknown"), try metadata(domain: "other")] {
            XCTAssertNil(event.safetyRecourse)
        }
        var state = CodexSafetyRecourseState()
        _ = state.consume(try metadata())
        XCTAssertNil(try error(state.consume(failure("bio_policy"))).safetyRecourse)
        _ = state.consume(try metadata()) // Old sequence must not repopulate state.
        XCTAssertNil(try error(state.consume(failure(sequence: 3))).safetyRecourse)
        let old = Data(#"{"code":"old","message":"Old error"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(AgentRuntimeError.self, from: old).safetyRecourse)
    }

    func testCommandSuggestionsAreFilteredAndCompletionClearsGuidance() throws {
        let event = try metadata(firstPrompt: "/run command")
        XCTAssertEqual(event.safetyRecourse?.suggestions.count, 2)
        var state = CodexSafetyRecourseState()
        _ = state.consume(event)
        _ = state.consume(.init(kind: .completed(.unavailable(), responseID: "response-1"), sequenceNumber: 2))
        XCTAssertNil(try error(state.consume(failure(sequence: 3))).safetyRecourse)
    }

    func testTransportCarriesMetadataIntoTerminalError() async throws {
        await TestURLProtocol.reset()
        let event = try metadata()
        let recourse = try XCTUnwrap(event.safetyRecourse)
        // Exercise the actual metadata wire event and per-stream adapter.
        let wire: [String: Any] = ["type": "response.metadata", "metadata": ["openai_chatgpt_moderation_metadata": [
            "safety_recourse": ["schema_version": 1, "domain": "cyber", "source": "user_request",
            "source_message": ["id": "m", "kind": "ordinary_message", "role": "user"],
            "topic": recourse.topic, "suggestions": recourse.suggestions.map { ["label": $0.label, "prompt_text": $0.promptText] }]]]]
        let first = String(decoding: try JSONSerialization.data(withJSONObject: wire), as: UTF8.self)
        let terminal = #"{"type":"response.failed","response":{"id":"r","error":{"code":"cyber_policy","message":"Blocked"}}}"#
        await TestURLProtocol.enqueue(.init(headers: ["Content-Type": "text/event-stream"],
            body: Data("data: \(first)\n\ndata: \(terminal)\n\n".utf8)))
        let client = CodexResponsesEventStreamClient(urlSession: makeTestURLSession(), decoder: JSONDecoder(), logger: AgentLogger())
        let stream = try await client.streamEvents(request: URLRequest(url: URL(string: "https://example.test/responses")!))
        var result: AgentRuntimeError?
        for try await item in stream { if case let .failed(error, _) = item.kind { result = error } }
        XCTAssertEqual(result?.safetyRecourse, recourse)
        await TestURLProtocol.reset()
    }
}
