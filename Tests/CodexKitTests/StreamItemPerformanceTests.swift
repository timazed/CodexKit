@testable import CodexKit
import XCTest

final class StreamItemPerformanceTests: XCTestCase {
    func testProjectionMatchesOriginalDecoderIncludingMalformedFields() throws {
        let fixtures = [
            #"{"type":"message","id":"m","role":"assistant","phase":"future_phase","content":[{"type":"output_text","text":"😀 café"},{"refusal":"no"}],"future":{"a":1}}"#,
            #"{"type":"message","role":"assistant","content":[]}"#,
            #"{"type":"function_call","name":"lookup","arguments":"{}","call_id":"c"}"#,
            #"{"type":"image_generation_call","id":"i","status":"completed","result":"aGVsbG8=","output_format":"png"}"#,
            #"{"type":"web_search_call","id":null,"status":"future_status","action":{"query":"a"}}"#,
            #"{"type":"web_search_call","action":null}"#,
            #"{"type":"future_item","anything":[1,true]}"#,
            #"{"type":"message","role":3,"content":[]}"#,
            #"{"type":"message","role":"assistant","content":[null]}"#,
            #"{"type":"message","role":"assistant","content":[3]}"#,
            #"{"type":"message","role":"assistant","content":null}"#,
            #"{"type":"message","role":"assistant"}"#,
            #"{"type":"message","role":null,"content":[]}"#,
            #"{"type":"message","role":"assistant","phase":{},"content":[]}"#,
            #"{"type":"function_call","name":"lookup","arguments":{},"call_id":"c"}"#,
            #"{"type":"image_generation_call","id":"i","status":"completed","result":123}"#,
            #"{"type":"web_search_call","status":false}"#,
            "null", "[]", "42"
        ]
        let decoder = JSONDecoder()
        for fixture in fixtures {
            let data = Data(fixture.utf8)
            let old = Result { try decoder.decode(LegacyStreamItem.self, from: data) }
            let new = Result { try decoder.decode(StreamItem.self, from: data) }
            switch (old, new) {
            case let (.success(old), .success(new)):
                XCTAssertEqual(new.rawValue, old.rawValue)
                XCTAssertEqual(String(reflecting: new.kind), String(reflecting: old.kind))
            case let (.failure(old), .failure(new)):
                XCTAssertEqual(errorLocation(old), errorLocation(new), fixture)
            default: XCTFail("Changed decoding acceptance: \(fixture)")
            }
        }
    }

    func testDecodingBenchmark() throws {
        guard ProcessInfo.processInfo.environment["CODEXKIT_RUN_PERFORMANCE_TESTS"] == "1" else {
            throw XCTSkip("Opt-in decoding benchmark")
        }
        for (name, item, iterations) in [
            ("small_text", message(String(repeating: "hello ", count: 10)), 2_000),
            ("large_text", message(String(repeating: "hello 😀 ", count: 20_000)), 50),
            ("image", JSONValue.object(["type": .string("image_generation_call"), "id": .string("i"),
                "status": .string("completed"), "result": .string(Data(repeating: 65, count: 1_000_000).base64EncodedString())]), 20)
        ] {
            let data = try JSONEncoder().encode(item)
            let decoder = JSONDecoder()
            var oldTimes: [Double] = [], newTimes: [Double] = []
            for _ in 0..<5 {
                let oldStart = ContinuousClock.now
                for _ in 0..<iterations {
                    let decoded = try decoder.decode(LegacyStreamItem.self, from: data)
                    XCTAssertEqual(decoded.rawValue.objectValue?["type"], item.objectValue?["type"])
                }
                oldTimes.append(milliseconds(oldStart.duration(to: .now)))
                let newStart = ContinuousClock.now
                for _ in 0..<iterations {
                    let decoded = try decoder.decode(StreamItem.self, from: data)
                    XCTAssertEqual(decoded.rawValue.objectValue?["type"], item.objectValue?["type"])
                }
                newTimes.append(milliseconds(newStart.duration(to: .now)))
            }
            print("BENCHMARK decode workload=\(name) bytes=\(data.count) iterations=\(iterations) old_median_ms=\(oldTimes.sorted()[2]) new_median_ms=\(newTimes.sorted()[2])")
        }
    }

    private func message(_ text: String) -> JSONValue {
        .object(["type": .string("message"), "role": .string("assistant"),
            "content": .array([.object(["type": .string("output_text"), "text": .string(text)])])])
    }

    private func errorLocation(_ error: Error) -> String {
        switch error {
        case let DecodingError.keyNotFound(key, context): return "missing:" + (context.codingPath + [key]).map(\.stringValue).joined(separator: ".")
        case let DecodingError.valueNotFound(_, context): return "null:" + context.codingPath.map(\.stringValue).joined(separator: ".")
        case let DecodingError.typeMismatch(_, context): return "type:" + context.codingPath.map(\.stringValue).joined(separator: ".")
        default: return "other"
        }
    }

    private func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }
}

private struct LegacyStreamItem: Decodable {
    let rawValue: JSONValue
    let kind: StreamItemKind
    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(JSONValue.self)
        switch ResponsesItemType(wireValue: rawValue.objectValue?["type"]) {
        case .message: kind = .message(try StreamMessageItem(from: decoder))
        case .functionCall: kind = .functionCall(try StreamFunctionCallItem(from: decoder))
        case .imageGenerationCall: kind = .imageGenerationCall(try StreamImageGenerationCallItem(from: decoder))
        case .webSearchCall: kind = .webSearchCall(try StreamWebSearchCallItem(from: decoder))
        default: kind = .other
        }
    }
}
