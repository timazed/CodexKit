@testable import CodexKit
import XCTest

final class ChatGPTOAuthWebAuthenticationTests: XCTestCase {
    func testAuthCallbackDispatchRunsOnMainActor() async {
        let finished = expectation(description: "callback dispatched on main actor")

        Task.detached {
            runAuthenticationCallbackOnMainActor {
                XCTAssertTrue(Thread.isMainThread)
                finished.fulfill()
            }
        }

        await fulfillment(of: [finished], timeout: 1.0)
    }

    func testAuthCallbackDispatchCanResumeContinuationFromBackgroundCallback() async throws {
        let expectedURL = try XCTUnwrap(URL(string: "assistant-runtime://callback"))

        let returnedURL = try await withCheckedThrowingContinuation { continuation in
            Task.detached {
                runAuthenticationCallbackOnMainActor {
                    XCTAssertTrue(Thread.isMainThread)
                    continuation.resume(returning: expectedURL)
                }
            }
        }

        XCTAssertEqual(returnedURL, expectedURL)
    }
}
