@testable import CodexKit
import XCTest

final class CodexRateLimitParserTests: XCTestCase {
    func testHeadersRetainUsableWindowsWhenOptionalTelemetryIsInvalid() throws {
        let response = try XCTUnwrap(HTTPURLResponse(url: URL(string: "https://example.com")!,
            statusCode: 200, httpVersion: nil, headerFields: [
                "x-codex-primary-used-percent": "25",
                "x-codex-primary-window-minutes": "300.5",
                "x-codex-primary-reset-at": "inf",
                "x-codex-secondary-used-percent": "NaN",
                "x-codex-credits-has-credits": "true",
                "x-codex-credits-unlimited": "false"
            ]))
        let limits = CodexRateLimitParser.headers(response)
        let snapshot = try XCTUnwrap(limits.first)
        XCTAssertEqual(limits.count, 1)
        XCTAssertEqual(snapshot.primary?.usedPercent, 25)
        XCTAssertNil(snapshot.primary?.windowDurationMinutes)
        XCTAssertNil(snapshot.primary?.resetsAt)
        XCTAssertNil(snapshot.secondary)
        XCTAssertEqual(snapshot.credits, .init(hasCredits: true, unlimited: false))

        for value in ["NaN", "inf", "invalid"] {
            let invalid = try XCTUnwrap(HTTPURLResponse(url: response.url!, statusCode: 200,
                httpVersion: nil, headerFields: ["x-codex-primary-used-percent": value]))
            XCTAssertTrue(CodexRateLimitParser.headers(invalid).isEmpty)
        }
    }

    func testEventNumbersRejectFractionalDurationsAndNonfiniteValues() throws {
        for minutes in [300.5, Double.infinity, Double.greatestFiniteMagnitude] {
            let snapshot = CodexRateLimitParser.event([
                "rate_limits": .object([
                    "primary": .object(["used_percent": .number(25),
                        "window_minutes": .number(minutes), "reset_at": .number(.nan)]),
                    "secondary": .object(["used_percent": .number(.infinity)])
                ])
            ])
            XCTAssertEqual(snapshot.primary?.usedPercent, 25)
            XCTAssertNil(snapshot.primary?.windowDurationMinutes)
            XCTAssertNil(snapshot.primary?.resetsAt)
            XCTAssertNil(snapshot.secondary)
        }
        let valid = CodexRateLimitParser.event([
            "rate_limits": .object(["primary": .object([
                "used_percent": .number(25), "window_minutes": .number(300), "reset_at": .number(123456)
            ])])
        ])
        XCTAssertEqual(valid.primary?.windowDurationMinutes, 300)
        XCTAssertEqual(valid.primary?.resetsAt, Date(timeIntervalSince1970: 123456))
    }
}
