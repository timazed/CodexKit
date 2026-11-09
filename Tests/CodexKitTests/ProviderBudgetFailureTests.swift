@testable import CodexKit
import XCTest

final class ProviderBudgetFailureTests: XCTestCase {
    override func setUp() async throws { await TestURLProtocol.reset() }
    override func tearDown() async throws { await TestURLProtocol.reset() }

    func testBudgetFailureIsTerminalDespiteRetryHeadersAndCustomRecoveryPolicy() async throws {
        await TestURLProtocol.enqueue(.init(statusCode: 503, headers: ["Retry-After": "0"],
            body: Data(#"{"error":{"code":"budget_reached","message":"Budget reached"}}"#.utf8)))
        await TestURLProtocol.enqueue(.init(body: Data(), inspect: { _ in XCTFail("Budget must not retry") }))
        let error = try await failure()
        XCTAssertTrue(error.http?.isSessionBudgetExceeded == true)
        XCTAssertEqual(error.retry?.isRetryable, false)
        XCTAssertFalse(AgentRecoveryRetryPolicy(retryableProviderCodes: ["budget_reached"]).canReplace(error))
    }

    func testStreamingBudgetFailureIgnoresLaterCompletion() async throws {
        await TestURLProtocol.enqueue(.init(body: Data("""
        data: {"type":"error","code":"budget_reached","message":"Budget reached"}

        data: {"type":"response.completed","response":{"id":"should-not-complete"}}

        """.utf8)))
        let error = try await failure()
        XCTAssertTrue(error.http?.isSessionBudgetExceeded == true)
        XCTAssertEqual(error.retry?.isRetryable, false)
    }

    func testPolicyCapacityRetriesBeforeOutputAndRetainsClassification() async throws {
        await TestURLProtocol.enqueue(.init(body: Data("""
        data: {"type":"error","code":"policy_capacity_unavailable","message":"Policy capacity"}

        """.utf8)))
        await TestURLProtocol.enqueue(.init(statusCode: 503, body: Data(
            #"{"error":{"code":"policy_capacity_unavailable","message":"Policy capacity"}}"#.utf8)))
        let error = try await failure(attempts: 2)
        XCTAssertTrue(error.http?.isPolicyCapacityUnavailable == true)
        XCTAssertEqual(error.retry?.attempt, 2)
        XCTAssertEqual(error.retry?.isRetryable, true)
        XCTAssertEqual(error.http?.providerCode, "policy_capacity_unavailable")
        XCTAssertEqual(try JSONDecoder().decode(AgentRuntimeError.self, from: JSONEncoder().encode(error)), error)
    }

    private func failure(attempts: Int = 3) async throws -> AgentRuntimeError {
        let backend = CodexResponsesBackend(configuration: .init(requestRetryPolicy:
            .init(maxAttempts: attempts, initialBackoff: 0, maxBackoff: 0, jitterFactor: 0)),
            urlSession: makeTestURLSession())
        let stream = try await backend.beginTurn(thread: .init(id: "thread"), history: [],
            message: Request(text: "Go"), instructions: "", responseFormat: nil,
            streamedStructuredOutput: nil, tools: [], session: demoSession())
        do {
            for try await _ in stream.events {}
            XCTFail("Expected failure")
            throw AgentRuntimeError(code: "test", message: "Expected failure")
        } catch { return try XCTUnwrap(error as? AgentRuntimeError) }
    }
}
