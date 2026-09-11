@testable import CodexKit
import Combine
import XCTest

final class StructuredValidationTests: XCTestCase {
    func testNestedSchemaEnforcesEnumRequiredAndAdditionalProperties() throws {
        let schema = JSONSchema.object(properties: ["items": .array(items: .object(
            properties: ["priority": .string(enum: ["low", "high"]), "score": .nullable(.integer)],
            required: ["priority", "score"]))], required: ["items"])
        try AgentJSONSchemaValidator.validateSchema(schema)
        let valid: JSONValue = .object(["items": .array([.object(["priority": .string("high"), "score": .null])])])
        XCTAssertNoThrow(try AgentJSONSchemaValidator.validate(valid, schema: schema))
        for item: JSONValue in [
            .object(["priority": .string("INVALID"), "score": .null]),
            .object(["priority": .string("high")]),
            .object(["priority": .string("high"), "score": .number(1.5)]),
            .object(["priority": .string("high"), "score": .null, "extra": .bool(true)])
        ] {
            XCTAssertThrowsError(try AgentJSONSchemaValidator.validate(.object(["items": .array([item])]), schema: schema))
        }
        XCTAssertNoThrow(try AgentJSONSchemaValidator.validate(.object([:]), schema: schema, partial: true))
        XCTAssertThrowsError(try AgentJSONSchemaValidator.validate(.object([:]), schema: schema))
    }

    func testRawSchemaReferencesAndAssertions() throws {
        let schema = JSONSchema.raw(.object([
            "$defs": .object(["score": .object(["type": .string("integer"), "minimum": .number(0), "maximum": .number(10)])]),
            "type": .string("array"), "minItems": .number(1), "maxItems": .number(3),
            "uniqueItems": .bool(true), "items": .object(["$ref": .string("#/$defs/score")])
        ]))
        try AgentJSONSchemaValidator.validateSchema(schema)
        XCTAssertNoThrow(try AgentJSONSchemaValidator.validate(.array([.number(1), .number(2)]), schema: schema))
        for value: JSONValue in [.array([]), .array([.number(-1)]), .array([.number(1), .number(1)]), .array([.number(11)])] {
            XCTAssertThrowsError(try AgentJSONSchemaValidator.validate(value, schema: schema))
        }
    }

    func testUnsupportedAssertionsCannotBeHiddenBehindReferences() {
        for schema in [
            JSONSchema.raw(.object(["type": .string("string"), "pattern": .string(".*")])),
            .raw(.object(["description": .object(["unknownConstraint": .bool(true)]), "$ref": .string("#/description")])),
            .raw(.object(["$ref": .string("https://example.com/schema")]))
        ] {
            XCTAssertThrowsError(try AgentJSONSchemaValidator.validateSchema(schema))
        }
    }

    func testInvalidTypeListEntriesCannotBeDiscardedDuringValueValidation() {
        for invalidType: JSONValue in [.string("future_type"), .number(42), .null] {
            let schema = JSONSchema.raw(.object(["type": .array([.string("string"), invalidType])]))
            XCTAssertThrowsError(try AgentJSONSchemaValidator.validateSchema(schema))
            for partial in [false, true] {
                XCTAssertThrowsError(try AgentJSONSchemaValidator.validate(.string("matches valid entry"),
                    schema: schema, partial: partial)) { error in
                    XCTAssertEqual((error as? AgentRuntimeError)?.code, "structured_output_schema_invalid")
                }
            }
        }
    }

    func testValidationBudgetCannotBeSwallowedByNegation() throws {
        let schema = JSONSchema.raw(.object(["not": .object(["$ref": .string("#")])]))
        try AgentJSONSchemaValidator.validateSchema(schema)
        XCTAssertThrowsError(try AgentJSONSchemaValidator.validate(.null, schema: schema)) { error in
            XCTAssertEqual((error as? AgentRuntimeError)?.code, "structured_output_validation_limit")
        }
    }

    func testLongFragmentedObjectOnlyDecodesWhenComplete() throws {
        var parser = CodexResponsesStructuredStreamParser()
        _ = try parser.consume(delta: CodexResponsesStructuredStreamParser.openTag + "{\"text\":\"")
        for _ in 0..<10_000 { _ = try parser.consume(delta: "word ") }
        XCTAssertEqual(parser.snapshotDecodeAttempts, 0)
        let events = try parser.consume(delta: "\"}" + CodexResponsesStructuredStreamParser.closeTag)
        XCTAssertEqual(parser.snapshotDecodeAttempts, 1)
        XCTAssertEqual(events.count, 1)
        if case let .structuredOutputPartial(value) = events.first {
            XCTAssertEqual(value.objectValue?["text"]?.stringValue?.count, 50_000)
        } else { XCTFail("Expected the complete JSON snapshot") }
    }

    func testParserUnderstandsEscapedStringsAndResetsBetweenMessages() throws {
        var parser = CodexResponsesStructuredStreamParser()
        let payload = #"{"text":"braces } { and \"quoted\"","items":[1,2]}"#
        let message = "Visible" + CodexResponsesStructuredStreamParser.openTag + payload + CodexResponsesStructuredStreamParser.closeTag
        for character in message { _ = try parser.consume(delta: String(character)) }
        XCTAssertEqual(parser.snapshotDecodeAttempts, 1)
        let first = parser.finalize(rawMessage: message)
        XCTAssertEqual(first.visibleText, "Visible")
        guard case .committed = first.finalResult else { return XCTFail("Expected valid JSON") }
        XCTAssertEqual(parser.snapshotDecodeAttempts, 0)
        _ = try parser.consume(delta: message)
        XCTAssertEqual(parser.snapshotDecodeAttempts, 1)
    }

    func testStructuredByteLimitAppliesBeforeCompletionAndToFinalOnlyMessages() throws {
        var parser = CodexResponsesStructuredStreamParser(maximumPayloadBytes: 16)
        _ = try parser.consume(delta: CodexResponsesStructuredStreamParser.openTag + "{\"x\":\"")
        XCTAssertThrowsError(try parser.consume(delta: String(repeating: "x", count: 17))) { error in
            XCTAssertEqual((error as? AgentRuntimeError)?.code, "structured_output_too_large")
        }
        for suffix in ["", CodexResponsesStructuredStreamParser.closeTag] {
            let result = parser.finalize(rawMessage: CodexResponsesStructuredStreamParser.openTag + String(repeating: "x", count: 32) + suffix)
            guard case let .invalid(failure) = result.finalResult else { return XCTFail("Expected oversized output rejection") }
            XCTAssertNil(failure.rawPayload)
        }
    }

    func testInactiveSubjectIsReleasedWithoutSubscribers() {
        var registry = AgentObservationSubjects<Int>(initialValue: 0)
        weak var subject: CurrentValueSubject<Int, Never>?
        do {
            let active = registry.subject(for: "thread")
            subject = active
            _ = registry.deactivate("thread")
            XCTAssertNotNil(subject)
        }
        XCTAssertNil(subject)
    }
}
