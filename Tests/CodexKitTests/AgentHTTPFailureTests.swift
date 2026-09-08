@testable import CodexKit
import XCTest

final class AgentHTTPFailureTests: XCTestCase {
    override func setUp() async throws { await TestURLProtocol.reset() }
    override func tearDown() async throws { await TestURLProtocol.reset() }

    func testHTTPFailurePreservesProviderFieldsAndRetryDecision() async throws {
        let body = Data(#"{"error":{"code":"quota_exhausted","type":"rate_limit","message":"Try later"}}"#.utf8)
        await TestURLProtocol.enqueue(.init(statusCode: 429, headers: ["Retry-After": "12", "x-request-id": "request-123"], body: body))
        let backend = CodexResponsesBackend(configuration: .init(requestRetryPolicy: .disabled), urlSession: makeTestURLSession())
        do {
            for try await _ in try await begin(backend).events {}
            XCTFail("Expected HTTP failure")
        } catch {
            let error = try XCTUnwrap(error as? AgentRuntimeError)
            XCTAssertEqual(error.code, "responses_http_status_429")
            XCTAssertEqual(error.http, .init(statusCode: 429, providerCode: "quota_exhausted", providerType: "rate_limit",
                requestID: "request-123", retryAfter: 12))
            XCTAssertEqual(error.retry, .init(attempt: 1, maximumAttempts: 1, isRetryable: true, safety: .beforeOutput))
            XCTAssertEqual(try JSONDecoder().decode(AgentRuntimeError.self, from: JSONEncoder().encode(error)), error)
        }
        let legacy = try JSONDecoder().decode(AgentRuntimeError.self, from: Data(#"{"code":"old","message":"Older stored failure"}"#.utf8))
        XCTAssertNil(legacy.http)
        XCTAssertNil(legacy.retry)
    }

    func testRetryAfterParsesSecondsAndDatesAndRejectsUnsafeValues() throws {
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(AgentHTTPFailure.retryAfter("15", now: now), 15)
        XCTAssertEqual(AgentHTTPFailure.retryAfter("Thu, 01 Jan 1970 00:00:30 GMT", now: now), 30)
        XCTAssertEqual(AgentHTTPFailure.retryAfter("99999999999", now: now), 86_400)
        for value in ["NaN", "inf", "-1", "unparseable"] { XCTAssertNil(AgentHTTPFailure.retryAfter(value, now: now)) }
        let policy = RequestRetryPolicy(initialBackoff: .infinity, maxBackoff: .nan, jitterFactor: .nan)
        XCTAssertEqual(policy.delayBeforeRetry(attempt: Int.max), 0)
        XCTAssertEqual(policy.delayBeforeRetry(attempt: Int.min), 0)
    }

    func testServerRetryDelayIsHonoredBeforeSecondAttempt() async throws {
        await TestURLProtocol.enqueue(.init(statusCode: 429, headers: ["Retry-After": "0.05"], body: Data()))
        await TestURLProtocol.enqueue(.init(body: Data("data: {\"type\":\"response.completed\",\"response\":{\"id\":\"done\"}}\n\n".utf8)))
        let backend = CodexResponsesBackend(configuration: .init(requestRetryPolicy: .init(initialBackoff: 0, jitterFactor: 0)),
            urlSession: makeTestURLSession())
        let start = ContinuousClock.now
        for try await _ in try await begin(backend).events {}
        XCTAssertGreaterThanOrEqual(start.duration(to: .now), .milliseconds(45))
    }

    func testVisibleOutputFailureCarriesUnsafeReplayMetadataAndProviderCode() async throws {
        await TestURLProtocol.enqueue(.init(body: Data("""
        data: {"type":"response.output_text.delta","delta":"Visible"}

        data: {"type":"response.failed","response":{"error":{"message":"Failure","code":"overloaded","type":"server_error"}}}

        """.utf8)))
        let backend = CodexResponsesBackend(urlSession: makeTestURLSession())
        do {
            for try await _ in try await begin(backend).events {}
            XCTFail("Expected stream failure")
        } catch {
            let error = try XCTUnwrap(error as? AgentRuntimeError)
            XCTAssertEqual(error.code, "responses_stream_failed")
            XCTAssertEqual(error.http?.providerCode, "overloaded")
            XCTAssertEqual(error.retry?.safety, .outputAlreadyEmitted)
            XCTAssertEqual(error.retry?.attempt, 1)
        }
    }

    func testStructuredContextCodesTakePrecedenceOverMessageHeuristics() async throws {
        let runtime = try AgentRuntime(configuration: .init(sessionProvider: DesignReadOnlyProvider(), backend: DesignBackend(),
            approvalPresenter: AutoApprovalPresenter(), stateStore: InMemoryRuntimeStateStore()))
        let context = await runtime.isContextPressureError(AgentRuntimeError(code: "http", message: "Capacity",
            http: .init(statusCode: 400, providerCode: "context_length_exceeded")))
        XCTAssertTrue(context)
        let unrelated = await runtime.isContextPressureError(AgentRuntimeError(code: "http", message: "Context limit mentioned in input",
            http: .init(statusCode: 400, providerCode: "invalid_image")))
        XCTAssertFalse(unrelated)
    }

    func testUnauthorizedRecoveryDelegatesToHostProvider() async throws {
        await TestURLProtocol.enqueue(.init(statusCode: 401, body: Data()))
        await TestURLProtocol.enqueue(.init(body: Data("""
        data: {"type":"response.output_item.done","item":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Recovered"}]}}

        data: {"type":"response.completed","response":{"id":"done"}}

        """.utf8)))
        let provider = DesignSessionProvider()
        let runtime = try AgentRuntime(configuration: .init(sessionProvider: provider,
            backend: CodexResponsesBackend(urlSession: makeTestURLSession()),
            approvalPresenter: AutoApprovalPresenter(), stateStore: InMemoryRuntimeStateStore()))
        let thread = try await runtime.createThread()
        let result = try await runtime.send(Request(text: "Go"), in: thread.id)
        XCTAssertEqual(result, "Recovered")
        let actions = await provider.actions
        XCTAssertEqual(actions, ["recover"])
    }

    func testUnauthorizedRecoveryCannotMoveAnExistingRequestToAnotherAccount() async throws {
        await TestURLProtocol.enqueue(.init(statusCode: 401, body: Data()))
        let runtime = try AgentRuntime(configuration: .init(sessionProvider: SwitchingSessionProvider(),
            backend: CodexResponsesBackend(urlSession: makeTestURLSession()),
            approvalPresenter: AutoApprovalPresenter(), stateStore: InMemoryRuntimeStateStore()))
        let thread = try await runtime.createThread()
        do { _ = try await runtime.send(Request(text: "Private request"), in: thread.id); XCTFail("Expected account replacement cancellation") }
        catch is CancellationError {}
    }

    func testImageGenerationRejectsOversizedHTTPErrorBeforeDecoding() async throws {
        await TestURLProtocol.enqueue(.init(statusCode: 500,
            body: Data(repeating: 32, count: AgentStoreLimits.maximumResponseErrorBodyByteCount + 1)))
        let client = AgentImageGenerationClient(urlSession: makeTestURLSession())
        do { _ = try await client.generate(prompt: "Image", session: demoSession()); XCTFail("Expected response size limit") }
        catch {
            XCTAssertEqual((error as? AgentRuntimeError)?.code, "image_generation_response_too_large")
            XCTAssertEqual((error as? AgentRuntimeError)?.http?.statusCode, 500)
        }
    }

    private func begin(_ backend: CodexResponsesBackend) async throws -> AgentTurnStream {
        try await backend.beginTurn(thread: .init(id: "thread"), history: [], message: Request(text: "Go"),
            instructions: "", responseFormat: nil, streamedStructuredOutput: nil, tools: [], session: demoSession())
    }
}

private struct SwitchingSessionProvider: AgentSessionProviding {
    func currentSession() async -> ChatGPTSession? { demoSession() }
    func recoverUnauthorizedSession(previousAccessToken: String?) async throws -> ChatGPTSession {
        .init(accessToken: "replacement", account: .init(id: "different-account", email: "other@example.com", plan: .plus))
    }
}
