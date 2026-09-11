@testable import CodexKit
import XCTest

final class UpstreamQuotaTests: XCTestCase {
    override func setUp() async throws { await TestURLProtocol.reset() }
    override func tearDown() async throws { await TestURLProtocol.reset() }

    func testQuotaErrorsStopAtFirstAttemptAndPreserveDiagnostics() async throws {
        let codes = ["insufficient_quota", "credit_balance_exhausted", "organization_spend_limit_exceeded",
            "project_spend_limit_exceeded", "organization_usage_limit_exceeded"]
        for code in codes + ["type-only"] {
            await TestURLProtocol.reset()
            let field = code == "type-only" ? "type" : "code"
            let value = code == "type-only" ? "insufficient_quota" : code
            await TestURLProtocol.enqueue(.init(statusCode: 429,
                headers: ["x-request-id": "quota-request", "Retry-After": "0"],
                body: Data("{\"error\":{\"\(field)\":\"\(value)\"}}".utf8)))
            await TestURLProtocol.enqueue(.init(body: Data(), inspect: { _ in XCTFail("Quota must not retry: \(code)") }))
            let backend = CodexResponsesBackend(configuration: .init(
                requestRetryPolicy: .init(maxAttempts: 3, initialBackoff: 0, maxBackoff: 0)), urlSession: makeTestURLSession())
            let turn = try await backend.beginTurn(thread: .init(id: "thread"), history: [], message: Request(text: "Hello"),
                instructions: "", responseFormat: nil, streamedStructuredOutput: nil, tools: [], session: demoSession())
            do {
                for try await _ in turn.events {}
                XCTFail("Expected quota failure")
            } catch let error as AgentRuntimeError {
                XCTAssertEqual(error.code, "quota_exceeded")
                XCTAssertEqual(error.http?.isQuotaExceeded, true)
                XCTAssertEqual(error.http?.requestID, "quota-request")
                XCTAssertEqual(error.retry?.attempt, 1)
                XCTAssertEqual(error.retry?.isRetryable, false)
            }
        }
    }

    func testOrdinaryRateLimitsStillRetry() async throws {
        for code in ["rate_limit_exceeded", "slow_down"] {
            await TestURLProtocol.enqueue(.init(statusCode: 429,
                body: Data("{\"error\":{\"code\":\"\(code)\"}}".utf8)))
            await TestURLProtocol.enqueue(.init(body: Data("data: {\"type\":\"response.completed\",\"response\":{\"id\":\"ok\"}}\n\n".utf8)))
            let backend = CodexResponsesBackend(configuration: .init(
                requestRetryPolicy: .init(maxAttempts: 2, initialBackoff: 0, maxBackoff: 0)), urlSession: makeTestURLSession())
            let turn = try await backend.beginTurn(thread: .init(id: "thread"), history: [], message: Request(text: "Hello"),
                instructions: "", responseFormat: nil, streamedStructuredOutput: nil, tools: [], session: demoSession())
            for try await _ in turn.events {}
        }
        XCTAssertFalse(AgentHTTPFailure(statusCode: 500, providerCode: "insufficient_quota").isQuotaExceeded)
    }
}
