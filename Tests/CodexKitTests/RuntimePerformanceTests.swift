@testable import CodexKit
import XCTest

/// Small repeatable microbenchmarks. Timing is reported, not asserted; the
/// correctness assertions remain independent of machine load and optimization.
final class RuntimePerformanceTests: XCTestCase {
    func testStructuredParsingScaling() throws {
        let fragment = "abcdefghijklmnop"
        for chunks in [500, 2_000, 8_000] {
            let prefix = "{\"text\":\""
            let decoder = JSONDecoder()
            let oldStart = ContinuousClock.now
            var oldBuffer = prefix
            for _ in 0..<chunks {
                oldBuffer.append(fragment)
                _ = try? decoder.decode(JSONValue.self, from: Data(oldBuffer.utf8))
            }
            oldBuffer.append("\"}")
            let expected = try decoder.decode(JSONValue.self, from: Data(oldBuffer.utf8))
            let oldDuration = oldStart.duration(to: .now)

            let newStart = ContinuousClock.now
            var parser = CodexResponsesStructuredStreamParser()
            _ = try parser.consume(delta: CodexResponsesStructuredStreamParser.openTag + prefix)
            for _ in 0..<chunks { _ = try parser.consume(delta: fragment) }
            let events = try parser.consume(delta: "\"}" + CodexResponsesStructuredStreamParser.closeTag)
            let newDuration = newStart.duration(to: .now)
            guard case let .structuredOutputPartial(actual) = events.first else { return XCTFail("Expected parsed output") }
            XCTAssertEqual(actual, expected)
            XCTAssertEqual(parser.snapshotDecodeAttempts, 1)
            print("BENCHMARK structured chunks=\(chunks) payload_bytes=\(oldBuffer.utf8.count) repeated_decode_ms=\(milliseconds(oldDuration)) incremental_ms=\(milliseconds(newDuration)) snapshot_decodes=1")
        }
    }

    private func milliseconds(_ duration: Duration) -> String {
        let parts = duration.components
        let value = Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
        return String(format: "%.3f", value)
    }
}
