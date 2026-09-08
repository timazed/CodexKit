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
            XCTAssertEqual(error as? AgentRuntimeError, AgentRuntimeError(code: "responses_http_status_400",
                message: "The ChatGPT responses request failed with status 400: {\"error\":\"bad request\"}",
                http: .init(statusCode: 400), retry: .init(attempt: 1, maximumAttempts: 3, isRetryable: false, safety: .beforeOutput)))
        }
    }

    func testBackendRetriesRetryableURLErrorCodesBeforeOutput() async throws {
        let retryableCodes: [URLError.Code] = [
            .timedOut,
            .cannotConnectToHost,
            .dnsLookupFailed,
            .networkConnectionLost,
            .notConnectedToInternet,
        ]

        for code in retryableCodes {
            try await assertBackendRetriesURLFailure(
                URLError(code),
                threadID: "thread-url-retry-\(code.rawValue)",
                expectedText: "Recovered after URL error \(code.rawValue)"
            )
        }
    }

    func testBackendRetriesNSURLErrorDomainFailuresBeforeOutput() async throws {
        try await assertBackendRetriesURLFailure(
            NSError(
                domain: NSURLErrorDomain,
                code: URLError.timedOut.rawValue
            ),
            threadID: "thread-ns-url-retry",
            expectedText: "Recovered after NSError URL failure"
        )
    }

    func testBackendRetriesWrappedRetryableURLErrorBeforeOutput() async throws {
        try await assertBackendRetriesURLFailure(
            NSError(
                domain: "CodexKitTests.Wrapper",
                code: 1,
                userInfo: [
                    NSUnderlyingErrorKey: URLError(.networkConnectionLost),
                ]
            ),
            threadID: "thread-wrapped-url-retry",
            expectedText: "Recovered after wrapped URL failure"
        )
    }

    func testBackendRetriesNetworkLossAfterPartialStreamBeforeCommit() async throws {
        let backend = CodexResponsesBackend(
            configuration: CodexResponsesBackendConfiguration(
                requestRetryPolicy: .init(maxAttempts: 2, initialBackoff: 0, maxBackoff: 0, jitterFactor: 0)
            ),
            urlSession: makeTestURLSession()
        )
        let session = ChatGPTSession(accessToken: "access-token", refreshToken: "refresh-token", account: ChatGPTAccount(id: "workspace-123", email: "taylor@example.com", plan: .plus))

        await TestURLProtocol.enqueue(.init(
            headers: ["Content-Type": "text/event-stream"],
            body: Data("""
            event: response.output_text.delta
            data: {"type":"response.output_text.delta","delta":"Hel"}

            """.utf8),
            completionError: URLError(.networkConnectionLost)
        ))
        await TestURLProtocol.enqueue(.init(headers: ["Content-Type": "text/event-stream"], body: Data("""
        event: response.output_text.delta
        data: {"type":"response.output_text.delta","delta":"Hello after retry"}

        event: response.output_item.done
        data: {"type":"response.output_item.done","item":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Hello after retry"}]}}

        event: response.completed
        data: {"type":"response.completed","response":{"id":"resp_delta_retry","usage":{"input_tokens":5,"input_tokens_details":{"cached_tokens":0},"output_tokens":2}}}

        """.utf8)))

        let turnStream = try await backend.beginTurn(thread: AgentThread(id: "thread-delta-retry"), history: [], message: Request(text: "Retry me"), instructions: "Resolved instructions", responseFormat: nil, streamedStructuredOutput: nil, tools: [], session: session)

        var deltas: [String] = []
        var assistantMessage: AgentMessage?
        for try await event in turnStream.events {
            switch event {
            case let .assistantMessageDelta(_, _, delta):
                deltas.append(delta)
            case let .assistantMessageCompleted(message):
                assistantMessage = message
            default:
                break
            }
        }

        XCTAssertEqual(deltas, ["Hello after retry"])
        XCTAssertEqual(assistantMessage?.text, "Hello after retry")
    }

    func testBackendDiscardsUncommittedReasoningItemsBeforeRetry() async throws {
        let backend = CodexResponsesBackend(
            configuration: CodexResponsesBackendConfiguration(
                requestRetryPolicy: .init(maxAttempts: 2, initialBackoff: 0, maxBackoff: 0, jitterFactor: 0)
            ),
            urlSession: makeTestURLSession()
        )
        let session = ChatGPTSession(accessToken: "access-token", refreshToken: "refresh-token", account: ChatGPTAccount(id: "workspace-123", email: "taylor@example.com", plan: .plus))

        await TestURLProtocol.enqueue(.init(
            headers: ["Content-Type": "text/event-stream"],
            body: Data("""
            event: response.output_item.done
            data: {"type":"response.output_item.done","output_index":0,"item":{"id":"rs_stale","type":"reasoning","content":[],"encrypted_content":"stale-ciphertext","summary":[]}}

            """.utf8),
            completionError: URLError(.networkConnectionLost)
        ))
        await TestURLProtocol.enqueue(.init(
            headers: ["Content-Type": "text/event-stream"],
            body: Data("""
            event: response.output_item.done
            data: {"type":"response.output_item.done","output_index":0,"item":{"id":"rs_fresh","type":"reasoning","content":[],"encrypted_content":"fresh-ciphertext","summary":[]}}

            event: response.output_item.done
            data: {"type":"response.output_item.done","output_index":1,"item":{"id":"msg_fresh","type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"Recovered"}]}}

            event: response.completed
            data: {"type":"response.completed","response":{"id":"resp_fresh","usage":{"input_tokens":5,"input_tokens_details":{"cached_tokens":0},"output_tokens":2}}}

            """.utf8)
        ))

        let turnStream = try await backend.beginTurn(
            thread: AgentThread(id: "thread-reasoning-retry"),
            history: [],
            message: Request(text: "Retry reasoning"),
            instructions: "Resolved instructions",
            responseFormat: nil,
            streamedStructuredOutput: nil,
            tools: [],
            session: session
        )

        var providerContext: AgentProviderContext?
        for try await event in turnStream.events {
            if case let .providerContextUpdated(_, context) = event {
                providerContext = context
            }
        }

        let items = try XCTUnwrap(providerContext?.payload.objectValue?["items"]?.arrayValue)
        let encryptedContents = items.compactMap {
            $0.objectValue?["encrypted_content"]?.stringValue
        }
        XCTAssertEqual(encryptedContents, ["fresh-ciphertext"])
    }

    private func assertBackendRetriesURLFailure(
        _ error: Error,
        threadID: String,
        expectedText: String
    ) async throws {
        let backend = CodexResponsesBackend(
            configuration: CodexResponsesBackendConfiguration(
                requestRetryPolicy: .init(maxAttempts: 2, initialBackoff: 0, maxBackoff: 0, jitterFactor: 0)
            ),
            urlSession: makeTestURLSession()
        )
        let session = ChatGPTSession(accessToken: "access-token", refreshToken: "refresh-token", account: ChatGPTAccount(id: "workspace-123", email: "taylor@example.com", plan: .plus))

        await TestURLProtocol.enqueue(.init(body: Data(), error: error))
        await TestURLProtocol.enqueue(.init(headers: ["Content-Type": "text/event-stream"], body: Data("""
        event: response.output_item.done
        data: {"type":"response.output_item.done","item":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"\(expectedText)"}]}}

        event: response.completed
        data: {"type":"response.completed","response":{"id":"resp_network_retry","usage":{"input_tokens":5,"input_tokens_details":{"cached_tokens":0},"output_tokens":2}}}

        """.utf8)))

        let turnStream = try await backend.beginTurn(thread: AgentThread(id: threadID), history: [], message: Request(text: "Retry me"), instructions: "Resolved instructions", responseFormat: nil, streamedStructuredOutput: nil, tools: [], session: session)

        var assistantMessage: AgentMessage?
        for try await event in turnStream.events {
            if case let .assistantMessageCompleted(message) = event {
                assistantMessage = message
            }
        }

        XCTAssertEqual(assistantMessage?.text, expectedText)
    }
}

private func drainEvents(_ events: AsyncThrowingStream<AgentBackendEvent, Error>) async throws {
    for try await _ in events {}
}
