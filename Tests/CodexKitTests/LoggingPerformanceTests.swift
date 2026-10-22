import Foundation
import XCTest

final class LoggingPerformanceTests: XCTestCase {
    func testLogTimestampFormatMatchesOriginalIncludingFractionalAndHistoricalDates() {
        let formatter = ISO8601DateFormatter()
        for seconds in [-2_208_988_800.25, -1.25, 0, 0.999, 1_792_000_000.123, 4_102_444_800] {
            let date = Date(timeIntervalSince1970: seconds)
            XCTAssertEqual(date.ISO8601Format(), formatter.string(from: date))
        }
    }

    func testTimestampFormattingBenchmark() throws {
        guard ProcessInfo.processInfo.environment["CODEXKIT_RUN_PERFORMANCE_TESTS"] == "1" else {
            throw XCTSkip("Opt-in logging benchmark")
        }
        let date = Date(timeIntervalSince1970: 1_792_000_000)
        let expected = ISO8601DateFormatter().string(from: date)
        var oldTimes: [Double] = [], newTimes: [Double] = []
        for _ in 0..<5 {
            let oldStart = ContinuousClock.now
            for _ in 0..<2_000 { XCTAssertEqual(ISO8601DateFormatter().string(from: date), expected) }
            oldTimes.append(ms(oldStart.duration(to: .now)))
            let newStart = ContinuousClock.now
            for _ in 0..<2_000 { XCTAssertEqual(date.ISO8601Format(), expected) }
            newTimes.append(ms(newStart.duration(to: .now)))
        }
        print("BENCHMARK log_timestamp entries=2000 old_median_ms=\(oldTimes.sorted()[2]) new_median_ms=\(newTimes.sorted()[2])")
    }

    private func ms(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }
}
