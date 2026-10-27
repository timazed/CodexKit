import CodexKit
import XCTest

final class AgentImageGenerationEstimateTests: XCTestCase {
    func testDesktopCurveAnchorsAndLongRequestsNeverClaimCompletion() {
        for (seconds, expected) in [(0.0, 3), (4.5, 25), (24.75, 58), (38.25, 88), (45, 90), (90, 97), (1_000, 99)] {
            XCTAssertEqual(AgentImageGenerationEstimate.percent(elapsedSeconds: seconds), expected)
        }
        var previous = 3
        for second in 0...1_000 {
            let value = AgentImageGenerationEstimate.percent(elapsedSeconds: Double(second))
            XCTAssertGreaterThanOrEqual(value, previous)
            XCTAssertLessThan(value, 100)
            previous = value
        }
    }

    func testInvalidAndNegativeElapsedTimesStayBounded() {
        XCTAssertEqual(AgentImageGenerationEstimate.percent(elapsedSeconds: -1), 3)
        XCTAssertEqual(AgentImageGenerationEstimate.percent(elapsedSeconds: .nan), 3)
        XCTAssertEqual(AgentImageGenerationEstimate.percent(elapsedSeconds: .infinity), 99)
        XCTAssertEqual(AgentImageGenerationEstimate.percent(elapsedSeconds: -.infinity), 3)
    }
}
