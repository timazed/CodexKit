@testable import CodexKit
import XCTest

final class AgentOutputDecoderTests: XCTestCase {
    struct Record: Codable, Sendable, Equatable { let id: UInt64; let text: String }
    let records = AgentRecordResponseFormat(name: "records", record: Record.self)

    func testJSONLinesEveryByteSplitIncludingUTF8CRLFAndEOF() async throws {
        let source = #"{"id":9007199254740993,"text":"a\nb 😀 \"quoted\" \\"}"# + "\r\n" + #"{"id":2,"text":"last"}"#
        let bytes = Data(source.utf8)
        for split in 0 ... bytes.count {
            let decoder = try records.makeDecoder()
            let events = OutputEventRecorder<AgentRecordEvent<Record>>()
            try await decoder.consume(Data(bytes.prefix(split)), into: events.sink)
            try await decoder.consume(Data(bytes.dropFirst(split)), into: events.sink)
            let value = try await decoder.finish(into: events.sink)
            XCTAssertEqual(value.records.map(\.id), [9_007_199_254_740_993, 2])
            let count = await events.count()
            XCTAssertEqual(count, 2)
        }
    }

    func testRecordPreviewArrivesBeforeEOFAndMalformedRecordStopsImmediately() async throws {
        let decoder = try records.makeDecoder()
        let events = OutputEventRecorder<AgentRecordEvent<Record>>()
        try await decoder.consume(Data("{\"id\":1,\"text\":\"first\"}\n".utf8), into: events.sink)
        let before = await events.count()
        XCTAssertEqual(before, 1)
        do {
            try await decoder.consume(Data("{\"id\":2,\"id\":3,\"text\":\"bad\"}\n{\"id\":4,\"text\":\"never\"}\n".utf8), into: events.sink)
            XCTFail("Duplicate keys must fail on that record")
        } catch {}
        let after = await events.count()
        XCTAssertEqual(after, 1)
    }

    func testStrictJSONRejectsDuplicateEscapedKeysBlankAndMalformedLines() async throws {
        for source in ["\n", " \r\n", #"{"id":1,"\u0069d":2,"text":"bad"}"#,
                       #"{"id":1,"text":"bad",}"#, "{}\n\n", "```json\n{}\n```", "{\"id\":1,\"text\":\"a\nb\"}"] {
            let decoder = try records.makeDecoder()
            do {
                try await decoder.consume(Data(source.utf8), into: .init { _, _ in })
                _ = try await decoder.finish(into: .init { _, _ in })
                XCTFail("Accepted invalid JSON Lines: \(source)")
            } catch {}
        }
    }

    func testNativeJSONPreservesPrecisionAndStreamsRawUnicodeAtEveryBoundary() async throws {
        let format = AgentJSONResponseFormat<Record>(name: "record", schema: .object(
            properties: ["id": .integer, "text": .string()], required: ["id", "text"]))
        let source = #"{"id":9007199254740993,"text":"😀 café"}"#
        let decoder = try format.makeDecoder()
        let events = OutputEventRecorder<AgentJSONOutputEvent>()
        for byte in source.utf8 { try await decoder.consume(Data([byte]), into: events.sink) }
        let output = try await decoder.finish(into: events.sink)
        XCTAssertEqual(output.id, 9_007_199_254_740_993)
        let raw = await events.values().map { event in if case let .rawJSONDelta(text) = event { text } else { "" } }.joined()
        XCTAssertEqual(raw, source)
        let adapter = try XCTUnwrap(format.persistence)
        XCTAssertEqual(try adapter.decode(adapter.encode(output)), output)
    }

    func testRecordLimitsAndFinalCollectionValidator() async throws {
        var format = records
        format.minimumRecords = 1; format.maximumRecords = 1
        let empty = try format.makeDecoder()
        do { _ = try await empty.finish(into: .init { _, _ in }); XCTFail("Required a record") } catch {}
        let decoder = try format.makeDecoder()
        let line = Data("{\"id\":1,\"text\":\"a\"}\n".utf8)
        try await decoder.consume(line, into: .init { _, _ in })
        do { try await decoder.consume(line, into: .init { _, _ in }); XCTFail("Exceeded count") } catch {}
        format.limits.maximumSemanticUnitBytes = 16
        let bounded = try format.makeDecoder()
        do { try await bounded.consume(line, into: .init { _, _ in }); XCTFail("Exceeded bytes") } catch {}
    }
}

actor OutputEventRecorder<Event: Sendable> {
    private var events: [Event] = []
    nonisolated var sink: AgentOutputEventSink<Event> { .init { event, _ in await self.append(event) } }
    func append(_ event: Event) { events.append(event) }
    func values() -> [Event] { events }
    func count() -> Int { events.count }
}
