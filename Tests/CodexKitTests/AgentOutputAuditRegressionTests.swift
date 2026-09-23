@testable import CodexKit
import XCTest

final class AgentOutputAuditRegressionTests: XCTestCase {
    struct Record: Codable, Sendable { let id: Int }
    struct TypedResponse: AgentStructuredOutput, Codable {
        let id: Int
        static let responseFormat = AgentStructuredOutputFormat(
            name: "typed", description: "Existing typed response",
            schema: .object(
                properties: ["id": .integer], required: ["id"]), strict: false
        )
    }

    func testXMLSchemaPreflightHasIndependentDepthAndNodeBudgets() async throws {
        var limits = AgentStructuredOutputLimits()
        limits.maximumNestingDepth = 1
        limits.maximumSemanticUnits = 1
        let format = AgentXMLResponseFormat(name: "single", schema: .element("r", text: .string), limits: limits)
        let decoder = try format.makeDecoder()
        let sink = AgentOutputEventSink<AgentXMLOutputEvent> { _, _ in }
        try await decoder.consume(Data("<r>ok</r>".utf8), into: sink)
        let document = try await decoder.finish(into: sink)
        XCTAssertEqual(document.root.text, "ok")
        let restored = try XCTUnwrap(format.persistence).decode(Data(document.rawXML.utf8))
        XCTAssertEqual(restored.root, document.root)

        let nested = try format.makeDecoder()
        do {
            try await nested.consume(Data("<r><child/></r>".utf8), into: sink)
            _ = try await nested.finish(into: sink)
            XCTFail("The response depth limit must still apply")
        } catch is AgentOutputError {}
    }

    func testSchemaByteBudgetStillAppliesAndInvalidSchemaErrorsAreNotHidden() throws {
        var limits = AgentStructuredOutputLimits()
        limits.maximumSchemaBytes = 10
        XCTAssertThrowsError(
            try AgentXMLResponseFormat(
                name: "bounded", schema: .element("r"), limits: limits
            ).makeDecoder())

        let invalid = AgentXMLResponseFormat(name: "bad", schema: .element("r", text: .string(enum: [])))
        for operation in [
            { _ = try invalid.formatInstructions },
            { _ = try invalid.schemaRepresentation },
            { _ = try AgentPreparedOutput(invalid, isEphemeral: false) },
            { _ = try invalid.makeDecoder() },
        ] {
            XCTAssertThrowsError(try operation()) { error in
                guard case AgentOutputError.invalidFormat(let message) = error else {
                    return XCTFail("Lost the schema compiler error: \(error)")
                }
                XCTAssertEqual(message, "XML enumeration must contain at least one value.")
            }
        }
    }

    func testRecordDeliveryErrorsAndLimitsKeepTheirType() async throws {
        let format = AgentRecordResponseFormat<Record>(name: "records")
        let decoder = try format.makeDecoder()
        do {
            try await decoder.consume(
                Data("{\"id\":1}\n".utf8),
                into: .init { event, _ in
                    if case let .recordCompleted(index, _) = event { XCTAssertEqual(index, 0) }
                    throw AgentOutputError.limit("sink capacity")
                })
            XCTFail("Delivery must fail")
        } catch {
            guard case AgentOutputError.limit(let message) = error else {
                return XCTFail("Delivery error was wrapped: \(error)")
            }
            XCTAssertEqual(message, "sink capacity")
        }

        var bounded = format
        bounded.limits.maximumOutputBytes = 16
        let limited = try bounded.makeDecoder()
        do {
            try await limited.consume(Data("{\"id\":1}\n".utf8), into: .init { _, _ in })
            XCTFail("Decoded output must exceed this budget")
        } catch {
            guard case AgentOutputError.limit = error else { return XCTFail("Lost limit error: \(error)") }
        }
    }

    func testMalformedRecordCarriesStableIndexAndUnderlyingError() async throws {
        let decoder = try AgentRecordResponseFormat<Record>(name: "records").makeDecoder()
        let sink = AgentOutputEventSink<AgentRecordEvent<Record>> { _, _ in }
        try await decoder.consume(Data("{\"id\":1}\n".utf8), into: sink)
        do {
            try await decoder.consume(Data("{\"id\":\"not an integer\"}\n".utf8), into: sink)
            XCTFail("Malformed record must fail")
        } catch let error as AgentRecordDecodingError {
            XCTAssertEqual(error.recordIndex, 1)
            XCTAssertTrue(error.underlyingError is DecodingError)
        }
    }

    func testValidationEventCarriesRecordFailureDetailsWithoutCommitting() async throws {
        let source = "{\"id\":1}\n{\"id\":\"invalid\"}\n"
        let fixture = try await OutputRuntimeFixture(backend: OutputTestBackend(source: source))
        defer { fixture.cleanUp() }
        let format = AgentRecordResponseFormat<Record>(name: "records")
        var failure: AgentOutputFailure?
        do {
            for try await event in try await fixture.runtime.stream(
                Request(text: "Go"), in: fixture.thread.id, output: format)
            {
                if case let .validationFailed(_, value) = event { failure = value }
                if case .outputCommitted = event { XCTFail("Invalid records committed") }
            }
            XCTFail("Invalid stream succeeded")
        } catch {}
        let reported = try XCTUnwrap(failure)
        XCTAssertEqual(reported.recordIndex, 1)
        XCTAssertTrue(reported.underlyingError is AgentRecordDecodingError)
        let stored = try await fixture.runtime.fetchLatestOutput(in: fixture.thread.id, output: format)
        XCTAssertNil(stored)
    }

    func testJSONAdapterReusesExistingTypedSchemaAndFormatAliases() async throws {
        let format = AgentJSONResponseFormat(TypedResponse.self)
        XCTAssertEqual(format.responseFormat, TypedResponse.responseFormat)
        let decoder = try format.makeDecoder()
        try await decoder.consume(Data("{\"id\":42}".utf8), into: .init { _, _ in })
        let value: AgentJSONResponseFormat<TypedResponse>.Output = try await decoder.finish(into: .init { _, _ in })
        XCTAssertEqual(value.id, 42)
    }

    func testRuntimePreparesFormatPropertiesOnceBeforeCommit() async throws {
        let fixture = try await OutputRuntimeFixture(backend: OutputTestBackend(source: "hello"))
        defer { fixture.cleanUp() }
        let reads = FormatPropertyReads()
        let format = CountingTextFormat(reads: reads)
        let value = try await fixture.runtime.send(Request(text: "Go"), in: fixture.thread.id, output: format)
        XCTAssertEqual(value, "hello")
        XCTAssertEqual(reads.snapshot, ["instructions": 1, "schema": 1, "persistence": 1])
        let metadata = try await fixture.runtime.fetchLatestStructuredOutputMetadata(id: fixture.thread.id)
        XCTAssertEqual(metadata?.outputRepresentation?.schema, "schema-1")
    }

    func testToolRoundsAfterOutputBeginsAreRejectedBeforeAdmission() async throws {
        for mode in [OutputTestBackend.Mode.toolAfterOutput, .toolRoundAfterOutput] {
            let backend = OutputTestBackend(source: "{\"id\":1}\n", mode: mode)
            let fixture = try await OutputRuntimeFixture(backend: backend)
            defer { fixture.cleanUp() }
            let format = AgentRecordResponseFormat<Record>(name: "records")
            var sawPreview = false
            do {
                for try await event in try await fixture.runtime.stream(
                    Request(text: "Go"), in: fixture.thread.id, output: format
                ) {
                    switch event {
                    case .format: sawPreview = true
                    case .lifecycle(.toolCallStarted): XCTFail("Late tool call was admitted: \(mode)")
                    case .outputCommitted: XCTFail("Output committed after a late tool round: \(mode)")
                    default: break
                    }
                }
                XCTFail("Late tool round was accepted: \(mode)")
            } catch {
                guard case AgentOutputError.protocolViolation = error else {
                    return XCTFail("Expected a protocol violation, got \(error)")
                }
            }
            XCTAssertTrue(sawPreview)
            let stored = try await fixture.runtime.fetchLatestOutput(in: fixture.thread.id, output: format)
            XCTAssertNil(stored)
        }
    }

    func testRecordRestorationRechecksBoundsDepthAndSchema() async throws {
        let source = "{\"id\":1}\n{\"id\":2}\n"
        let fixture = try await OutputRuntimeFixture(backend: OutputTestBackend(source: source))
        defer { fixture.cleanUp() }
        let schema = JSONSchema.raw(.object([
            "type": .string("object"),
            "properties": .object(["id": .object(["type": .string("integer"), "maximum": .number(2)])]),
            "required": .array([.string("id")]),
        ]))
        let format = AgentRecordResponseFormat<Record>(
            name: "records", schema: schema, minimumRecords: 2, maximumRecords: 2)
        _ = try await fixture.runtime.send(Request(text: "Go"), in: fixture.thread.id, output: format)
        let metadata = try await fixture.runtime.fetchLatestStructuredOutputMetadata(id: fixture.thread.id)
        let representation = try XCTUnwrap(metadata?.outputRepresentation)
        XCTAssertEqual(try representation.restore(using: format).records.count, 2)

        var bounded = format
        bounded.minimumRecords = 1
        bounded.maximumRecords = 1
        bounded.limits.maximumSemanticUnits = 1
        XCTAssertThrowsError(try representation.restore(using: bounded)) { error in
            guard case AgentOutputError.limit = error else { return XCTFail("Lost record count limit: \(error)") }
        }
        do {
            _ = try await fixture.runtime.fetchLatestOutput(in: fixture.thread.id, output: bounded)
            XCTFail("Runtime restored records above the current count limit")
        } catch AgentOutputError.limit {}

        var smallRecord = format
        smallRecord.limits.maximumSemanticUnitBytes = 6
        XCTAssertThrowsError(try representation.restore(using: smallRecord)) { error in
            guard case AgentOutputError.limit = error else { return XCTFail("Lost record byte limit: \(error)") }
        }

        var shallow = format
        shallow.limits.maximumNestingDepth = 1
        XCTAssertThrowsError(try representation.restore(using: shallow)) { error in
            guard case AgentOutputError.limit = error else { return XCTFail("Lost JSON depth limit: \(error)") }
        }

        let adapter = try XCTUnwrap(format.persistence)
        XCTAssertThrowsError(try adapter.decode(JSONEncoder().encode(AgentRecordCollection(records: [Record(id: 1)])))) {
            error in
            guard case AgentOutputError.invalidOutput = error else {
                return XCTFail("Lost minimum record bound: \(error)")
            }
        }
        XCTAssertThrowsError(try adapter.decode(JSONEncoder().encode(AgentRecordCollection(records: [Record(id: 3), Record(id: 2)])))) {
            error in
            XCTAssertTrue(error is AgentRuntimeError, "Stored record bypassed its schema: \(error)")
        }
    }

    func testXMLParserClassifiesBudgetsAsLimitsAndSyntaxAsInvalidOutput() async throws {
        let xml = Data("<r><child>ok</child></r>".utf8)
        let schema = XMLSchema.element("r", children: .sequence([.element("child", text: .string)]))
        for configure in [
            { (limits: inout AgentStructuredOutputLimits) in limits.maximumNestingDepth = 1 },
            { (limits: inout AgentStructuredOutputLimits) in limits.maximumSemanticUnits = 1 },
            { (limits: inout AgentStructuredOutputLimits) in limits.maximumOutputBytes = 32 },
            { (limits: inout AgentStructuredOutputLimits) in limits.maximumSemanticUnitBytes = 4 },
        ] {
            var limits = AgentStructuredOutputLimits()
            configure(&limits)
            let format = AgentXMLResponseFormat(name: "xml", schema: schema, limits: limits)
            let decoder = try format.makeDecoder()
            let sink = AgentOutputEventSink<AgentXMLOutputEvent> { _, _ in }
            do {
                try await decoder.consume(xml, into: sink)
                _ = try await decoder.finish(into: sink)
                XCTFail("XML budget was accepted")
            } catch {
                guard case AgentOutputError.limit = error else { return XCTFail("Lost XML limit: \(error)") }
            }
            let adapter = try XCTUnwrap(format.persistence)
            XCTAssertThrowsError(try adapter.decode(xml)) { error in
                guard case AgentOutputError.limit = error else { return XCTFail("Lost restore limit: \(error)") }
            }
        }

        let normal = AgentXMLResponseFormat(name: "xml", schema: schema)
        let adapter = try XCTUnwrap(normal.persistence)
        XCTAssertThrowsError(try adapter.decode(Data("<r><child></r>".utf8))) { error in
            guard case AgentOutputError.invalidOutput = error else {
                return XCTFail("Malformed XML was reported as a budget failure: \(error)")
            }
        }

        var limits = AgentStructuredOutputLimits()
        limits.maximumNestingDepth = 1
        let bounded = AgentXMLResponseFormat(name: "xml", schema: schema, limits: limits)
        let fixture = try await OutputRuntimeFixture(backend: OutputTestBackend(source: String(decoding: xml, as: UTF8.self)))
        defer { fixture.cleanUp() }
        var failure: AgentOutputFailure?
        do {
            for try await event in try await fixture.runtime.stream(
                Request(text: "Go"), in: fixture.thread.id, output: bounded
            ) {
                if case let .validationFailed(_, value) = event { failure = value }
                if case .outputCommitted = event { XCTFail("Over-limit XML committed") }
            }
            XCTFail("Over-limit XML stream succeeded")
        } catch {
            guard case AgentOutputError.limit = error else { return XCTFail("Lost stream limit: \(error)") }
        }
        let underlying = try XCTUnwrap(failure?.underlyingError)
        guard case AgentOutputError.limit = underlying else {
            return XCTFail("The validation event lost its XML limit: \(underlying)")
        }
    }
}

private struct CountingTextFormat: AgentOutputFormat {
    let reads: FormatPropertyReads
    let name = "counting-text"
    let codecIdentifier = "test.counting-text"
    let limits = AgentStructuredOutputLimits()

    var formatInstructions: String { "Return text. Preparation \(reads.record("instructions"))." }
    var schemaRepresentation: String? { "schema-\(reads.record("schema"))" }
    var persistence: AgentOutputPersistence<String>? {
        _ = reads.record("persistence")
        return .json
    }

    func makeDecoder() throws -> AgentTextOutputDecoder {
        try AgentTextResponseFormat(limits: limits).makeDecoder()
    }
}

private final class FormatPropertyReads: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    var snapshot: [String: Int] { lock.withLock { counts } }

    func record(_ property: String) -> Int {
        lock.withLock {
            counts[property, default: 0] += 1
            return counts[property, default: 0]
        }
    }
}
