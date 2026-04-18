import CodexKit
import XCTest

extension CodexResponsesBackendTests {
    func testBackendRetriesTransientStatusCodeWithBackoffPolicy() async throws {
        let backend = CodexResponsesBackend(
            configuration: CodexResponsesBackendConfiguration(
                requestRetryPolicy: .init(
                    maxAttempts: 2,
                    initialBackoff: 0,
                    maxBackoff: 0,
                    jitterFactor: 0
                )
            ),
            urlSession: makeTestURLSession()
        )
        let session = ChatGPTSession(
            accessToken: "access-token",
            refreshToken: "refresh-token",
            account: ChatGPTAccount(id: "workspace-123", email: "taylor@example.com", plan: .plus)
        )

        await TestURLProtocol.enqueue(.init(statusCode: 503, headers: ["Content-Type": "application/json"], body: Data(#"{"error":"upstream overloaded"}"#.utf8)))
        await TestURLProtocol.enqueue(.init(headers: ["Content-Type": "text/event-stream"], body: Data("""
        event: response.output_item.done
        data: {"type":"response.output_item.done","item":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Recovered"}]}}

        event: response.completed
        data: {"type":"response.completed","response":{"id":"resp_retry","usage":{"input_tokens":5,"input_tokens_details":{"cached_tokens":0},"output_tokens":2}}}

        """.utf8)))

        let turnStream = try await backend.beginTurn(thread: AgentThread(id: "thread-retry"), history: [], message: Request(text: "Hi"), instructions: "Resolved instructions", responseFormat: nil, streamedStructuredOutput: nil, tools: [], session: session)

        var assistantMessage: AgentMessage?
        for try await event in turnStream.events {
            if case let .assistantMessageCompleted(message) = event {
                assistantMessage = message
            }
        }

        XCTAssertEqual(assistantMessage?.text, "Recovered")
    }

    func testBackendDoesNotRetryNonRetryableStatusCode() async throws {
        let backend = CodexResponsesBackend(
            configuration: CodexResponsesBackendConfiguration(
                requestRetryPolicy: .init(maxAttempts: 3, initialBackoff: 0, maxBackoff: 0, jitterFactor: 0)
            ),
            urlSession: makeTestURLSession()
        )
        let session = ChatGPTSession(accessToken: "access-token", refreshToken: "refresh-token", account: ChatGPTAccount(id: "workspace-123", email: "taylor@example.com", plan: .plus))

        await TestURLProtocol.enqueue(.init(statusCode: 400, headers: ["Content-Type": "application/json"], body: Data(#"{"error":"bad request"}"#.utf8)))
        await TestURLProtocol.enqueue(.init(headers: ["Content-Type": "text/event-stream"], body: Data(), inspect: { _ in XCTFail("Non-retryable 400 should not trigger a retry.") }))

        let turnStream = try await backend.beginTurn(thread: AgentThread(id: "thread-no-retry"), history: [], message: Request(text: "Hi"), instructions: "Resolved instructions", responseFormat: nil, streamedStructuredOutput: nil, tools: [], session: session)

        await XCTAssertThrowsErrorAsync(try await drainEvents(turnStream.events)) { error in
            XCTAssertEqual(error as? AgentRuntimeError, AgentRuntimeError(code: "responses_http_status_400", message: "The ChatGPT responses request failed with status 400: {\"error\":\"bad request\"}"))
        }
    }

    func testBackendRetriesWhenNetworkConnectionIsLostBeforeOutput() async throws {
        let backend = CodexResponsesBackend(
            configuration: CodexResponsesBackendConfiguration(
                requestRetryPolicy: .init(maxAttempts: 2, initialBackoff: 0, maxBackoff: 0, jitterFactor: 0)
            ),
            urlSession: makeTestURLSession()
        )
        let session = ChatGPTSession(accessToken: "access-token", refreshToken: "refresh-token", account: ChatGPTAccount(id: "workspace-123", email: "taylor@example.com", plan: .plus))

        await TestURLProtocol.enqueue(.init(body: Data(), error: URLError(.networkConnectionLost)))
        await TestURLProtocol.enqueue(.init(headers: ["Content-Type": "text/event-stream"], body: Data("""
        event: response.output_item.done
        data: {"type":"response.output_item.done","item":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Recovered after network loss"}]}}

        event: response.completed
        data: {"type":"response.completed","response":{"id":"resp_network_retry","usage":{"input_tokens":5,"input_tokens_details":{"cached_tokens":0},"output_tokens":2}}}

        """.utf8)))

        let turnStream = try await backend.beginTurn(thread: AgentThread(id: "thread-network-retry"), history: [], message: Request(text: "Retry me"), instructions: "Resolved instructions", responseFormat: nil, streamedStructuredOutput: nil, tools: [], session: session)

        var assistantMessage: AgentMessage?
        for try await event in turnStream.events {
            if case let .assistantMessageCompleted(message) = event {
                assistantMessage = message
            }
        }

        XCTAssertEqual(assistantMessage?.text, "Recovered after network loss")
    }
}

private func drainEvents(_ events: AsyncThrowingStream<AgentBackendEvent, Error>) async throws {
    for try await _ in events {}
}
