import CodexKit
import XCTest

final class ReasoningEffortTests: XCTestCase {
    func testKnownEffortsMatchCodexOrderingAndWireValues() {
        let efforts: [(ReasoningEffort, String)] = [
            (.none, "none"),
            (.minimal, "minimal"),
            (.low, "low"),
            (.medium, "medium"),
            (.high, "high"),
            (.extraHigh, "xhigh"),
            (.max, "max"),
            (.ultra, "ultra"),
        ]

        XCTAssertEqual(ReasoningEffort.allCases, efforts.map(\.0))
        for (effort, rawValue) in efforts {
            XCTAssertEqual(effort.rawValue, rawValue)
            XCTAssertEqual(ReasoningEffort(rawValue: rawValue), effort)
        }
    }

    func testCodablePreservesCustomValuesAndMigratesLegacyExtraHigh() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let custom = ReasoningEffort.custom("future")
        let customData = try encoder.encode(custom)
        XCTAssertEqual(String(decoding: customData, as: UTF8.self), "\"future\"")
        XCTAssertEqual(try decoder.decode(ReasoningEffort.self, from: customData), custom)

        let legacyExtraHigh = Data("\"extraHigh\"".utf8)
        XCTAssertEqual(
            try decoder.decode(ReasoningEffort.self, from: legacyExtraHigh),
            .extraHigh
        )
        XCTAssertEqual(String(decoding: try encoder.encode(ReasoningEffort.extraHigh), as: UTF8.self), "\"xhigh\"")
    }

    func testEmptyReasoningEffortIsRejected() {
        XCTAssertNil(ReasoningEffort(rawValue: ""))
        XCTAssertThrowsError(try JSONDecoder().decode(ReasoningEffort.self, from: Data("\"\"".utf8)))
    }
}
