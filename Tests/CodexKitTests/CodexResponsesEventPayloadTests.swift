@testable import CodexKit
import XCTest

final class CodexResponsesEventPayloadTests: XCTestCase {
    func testTextEventDecodesOnlyItsOwnPayloadFields() throws {
        let payload = try decode(#"{"type":"response.output_text.delta","delta":"Hello","sequence_number":7,"response":false,"item":42}"#)
        guard case let .assistantTextDelta(text) = payload.event.kind else { return XCTFail("Expected text delta") }
        XCTAssertEqual(text, "Hello")
        XCTAssertEqual(payload.event.sequenceNumber, 7)
    }

    func testUnknownEventCanCarryNewPayloadShapes() throws {
        let payload = try decode(#"{"type":"response.future","delta":{},"response":false,"item":[],"sequence_number":9}"#)
        guard case .other = payload.event.kind else { return XCTFail("Expected ignored event") }
        XCTAssertEqual(payload.type, "response.future")
        XCTAssertEqual(payload.event.sequenceNumber, 9)
        XCTAssertFalse(payload.logsResponsePayload)
    }

    func testMalformedKnownPayloadReportsItsOriginalNestedCodingPath() {
        XCTAssertThrowsError(try decode(#"{"type":"response.output_item.done","item":{"type":"function_call","name":"lookup","call_id":"call","arguments":false}}"#)) { error in
            guard case let DecodingError.typeMismatch(_, context) = error else { return XCTFail("Expected type mismatch: \(error)") }
            XCTAssertEqual(context.codingPath.map(\.stringValue), ["item", "arguments"])
        }
    }

    func testMissingOptionalFieldsStillProduceIgnoredEvents() throws {
        for value in [#"{"type":"response.output_text.delta"}"#, #"{"type":"response.output_item.done"}"#] {
            guard case .other = try decode(value).event.kind else { return XCTFail("Expected ignored incomplete event") }
        }
    }

    func testRateLimitsIgnoreSequenceMetadataAndKeepFiniteWindowChecks() throws {
        let payload = try decode(#"{"type":"codex.rate_limits","sequence_number":"future_metadata","rate_limits":{"primary":{"used_percent":25,"window_minutes":300,"reset_at":123456}}}"#)
        guard case let .rateLimits(snapshots) = payload.event.kind else { return XCTFail("Expected limits") }
        XCTAssertEqual(snapshots.first?.primary?.usedPercent, 25)
        XCTAssertNil(payload.event.sequenceNumber)
    }

    func testSearchItemDecodesTypedProgressAndPreservesRawOutput() throws {
        let value = #"{"type":"response.output_item.done","item":{"type":"web_search_call","id":"search","status":"future_state","action":{"type":"search","query":"weather"},"future_field":true}}"#
        let payload = try decode(value)
        guard case let .outputItem(item, _) = payload.event.kind,
              case let .webSearch(_, status, action) = item.completedProgress else { return XCTFail("Expected search item") }
        XCTAssertEqual(status, .custom("future_state"))
        XCTAssertEqual(action?.objectValue?["query"], .string("weather"))
        XCTAssertEqual(item.rawValue.objectValue?["future_field"], .bool(true))
        XCTAssertTrue(payload.logsResponsePayload)
    }

    private func decode(_ value: String) throws -> CodexResponsesEventPayload {
        try JSONDecoder().decode(CodexResponsesEventPayload.self, from: Data(value.utf8))
    }
}
