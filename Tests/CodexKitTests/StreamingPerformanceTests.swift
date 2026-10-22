@testable import CodexKit
@testable import CodexKitUI
import XCTest

@MainActor
final class StreamingPerformanceTests: XCTestCase {
    func testBatchPreservesUnicodeAndFlushesExactlyOnce() {
        let batch = StreamingTextBatcher()
        var values: [String] = []
        for delta in ["Hello", " 😀", " café", "\n"] {
            batch.append(delta) { values.append($0) }
        }
        XCTAssertTrue(values.isEmpty)
        batch.flush()
        batch.flush()
        XCTAssertEqual(values, ["Hello 😀 café\n"])
    }

    func testResetDiscardsPreviousSelectionAndCancelsItsTimer() async {
        let batch = StreamingTextBatcher(interval: .milliseconds(10))
        let published = expectation(description: "New selection is published by the timer")
        published.assertForOverFulfill = true
        var values: [String] = []
        batch.append("old chat") { values.append($0) }
        batch.reset()
        batch.append("new chat") {
            values.append($0)
            published.fulfill()
        }
        await fulfillment(of: [published], timeout: 5)
        XCTAssertEqual(values, ["new chat"])
        batch.flush()
        XCTAssertEqual(values.count, 1)
    }

    func testUnclassifiedBufferPreservesInterleavedMessagesAndRejectsReordering() async throws {
        let format = AgentTextResponseFormat()
        let session = AgentOutputSession(prepared: try AgentPreparedOutput(format, isEphemeral: true),
            decoder: try format.makeDecoder(), executionID: UUID(), threadID: "thread",
            channel: AgentEventChannel<AgentOutputEvent<AgentTextOutputEvent, String>>(), box: .init())
        for _ in 0..<1_000 {
            for id in ["a", "b"] {
                try await session.consume(.init(threadID: "thread", turnID: "turn", messageID: id,
                    phase: nil, text: id + "😀"))
            }
        }
        let pending = await session.pending
        XCTAssertEqual(pending["a"]?.bytes, Data(String(repeating: "a😀", count: 1_000).utf8))
        XCTAssertEqual(pending["b"]?.bytes, Data(String(repeating: "b😀", count: 1_000).utf8))
        do {
            try await session.consume(.init(threadID: "thread", turnID: "turn", messageID: "a",
                contentIndex: 2, phase: nil, text: "invalid"))
            XCTFail("Must reject skipped content indices")
        } catch {}
        let after = await session.pending
        XCTAssertEqual(after["a"]?.bytes, pending["a"]?.bytes)
    }

    /// Run with CODEXKIT_RUN_PERFORMANCE_TESTS=1 swift test -c release --filter StreamingPerformanceTests.
    /// Kernel comparison: identical bytes and dictionary layout, original versus modifying accessor.
    func testBufferBenchmark() throws {
        try requireBenchmarks()
        let fragment = Data(repeating: 65, count: 256)
        for count in [2_000, 8_000, 16_000] {
            var oldTimes: [Double] = [], newTimes: [Double] = []
            for _ in 0..<5 {
                var old: [String: (bytes: Data, index: Int)] = [:]
                let oldStart = ContinuousClock.now
                for _ in 0..<count {
                    var part = old["message"] ?? (Data(), -1)
                    part.bytes.append(fragment)
                    part.index = 0
                    old["message"] = part
                }
                oldTimes.append(ms(oldStart.duration(to: .now)))
                var new: [String: (bytes: Data, index: Int)] = [:]
                let newStart = ContinuousClock.now
                for _ in 0..<count {
                    new["message", default: (Data(), -1)].bytes.append(fragment)
                    new["message"]?.index = 0
                }
                newTimes.append(ms(newStart.duration(to: .now)))
                XCTAssertEqual(old["message"]?.bytes, new["message"]?.bytes)
                XCTAssertEqual(new["message"]?.bytes.count, count * fragment.count)
            }
            print("BENCHMARK buffer chunks=\(count) bytes=\(count * fragment.count) old_median_ms=\(oldTimes.sorted()[2]) new_median_ms=\(newTimes.sorted()[2])")
        }
    }

    /// Simulated frame boundaries isolate publication work; this does not measure SwiftUI rendering.
    func testUIBurstBenchmark() throws {
        try requireBenchmarks()
        let fragment = "hello 😀 "
        for count in [2_000, 8_000, 16_000] {
            var old = "", new = ""
            var oldPublications = 0, newPublications = 0
            let oldStart = ContinuousClock.now
            for _ in 0..<count { old.append(fragment); oldPublications += 1 }
            let oldMS = ms(oldStart.duration(to: .now))
            let batch = StreamingTextBatcher()
            let newStart = ContinuousClock.now
            for index in 0..<count {
                batch.append(fragment) { new.append($0); newPublications += 1 }
                if (index + 1).isMultiple(of: 32) { batch.flush() }
            }
            batch.flush()
            let newMS = ms(newStart.duration(to: .now))
            XCTAssertEqual(new, old)
            XCTAssertEqual(newPublications, (count + 31) / 32)
            print("BENCHMARK ui chunks=\(count) old_publications=\(oldPublications) new_publications=\(newPublications) old_ms=\(oldMS) new_ms=\(newMS)")
        }
    }

    private func requireBenchmarks() throws {
        guard ProcessInfo.processInfo.environment["CODEXKIT_RUN_PERFORMANCE_TESTS"] == "1" else {
            throw XCTSkip("Opt-in streaming benchmarks")
        }
    }

    private func ms(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }
}
