import CodexKit
import XCTest

extension AgentRuntimeTests {
    func testRuntimeLoggingEmitsAuthRuntimeAndPersistenceEntries() async throws {
        let buffer = RuntimeLogBuffer()
        let logging = AgentLoggingConfiguration(
            minimumLevel: .debug,
            sink: RuntimeTestLogSink(buffer: buffer)
        )
        let runtime = try AgentRuntime(configuration: .init(
            authProvider: DemoChatGPTAuthProvider(),
            secureStore: KeychainSessionSecureStore(
                service: "CodexKitTests.ChatGPTSession",
                account: UUID().uuidString
            ),
            backend: InMemoryAgentBackend(),
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: InMemoryRuntimeStateStore(logging: logging),
            logging: logging
        ))

        _ = try await runtime.restore()
        _ = try await runtime.useSession(demoSession())
        let thread = try await runtime.createThread(title: "Logging")
        _ = try await runtime.send(
            Request(text: "Log this turn"),
            in: thread.id
        )

        let entries = buffer.entries
        XCTAssertTrue(entries.contains { $0.category == .auth && $0.message.contains("Session loaded") })
        XCTAssertTrue(entries.contains { $0.category == .runtime && $0.message.contains("Thread created") })
        XCTAssertTrue(entries.contains { $0.category == .runtime && $0.message.contains("Starting streamed message") })
        XCTAssertTrue(entries.contains { $0.category == .persistence })
    }
}

extension CodexResponsesBackendTests {
    func testBackendDebugLoggingEmitsRequestAndResponsePayloadsWithoutStreamNoise() async throws {
        let buffer = RuntimeLogBuffer()
        let logging = AgentLoggingConfiguration(
            minimumLevel: .debug,
            sink: RuntimeTestLogSink(buffer: buffer)
        )
        let backend = CodexResponsesBackend(
            configuration: CodexResponsesBackendConfiguration(
                requestRetryPolicy: .init(
                    maxAttempts: 2,
                    initialBackoff: 0,
                    maxBackoff: 0,
                    jitterFactor: 0
                ),
                logging: logging
            ),
            urlSession: makeTestURLSession()
        )
        let session = ChatGPTSession(
            accessToken: "access-token",
            refreshToken: "refresh-token",
            account: ChatGPTAccount(
                id: "workspace-123",
                email: "taylor@example.com",
                plan: .plus
            )
        )

        await TestURLProtocol.enqueue(.init(
            statusCode: 503,
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"error":"upstream overloaded"}"#.utf8)
        ))
        await TestURLProtocol.enqueue(.init(
            headers: ["Content-Type": "text/event-stream"],
            body: Data("""
            event: response.output_item.done
            data: {"type":"response.output_item.done","item":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Recovered"}]}}

            event: response.completed
            data: {"type":"response.completed","response":{"id":"resp_retry","usage":{"input_tokens":5,"input_tokens_details":{"cached_tokens":0},"output_tokens":2}}}

            """.utf8)
        ))

        let turnStream = try await backend.beginTurn(
            thread: AgentThread(id: "thread-retry"),
            history: [],
            message: Request(text: "Hi"),
            instructions: "Resolved instructions",
            responseFormat: nil,
            streamedStructuredOutput: nil,
            tools: [],
            session: session
        )

        for try await _ in turnStream.events {}

        let entries = buffer.entries
        XCTAssertTrue(entries.contains { $0.category == .retry && $0.message.contains("Retrying backend turn pass") })
        XCTAssertTrue(entries.contains { $0.category == .network && $0.message.contains("Opening responses event stream") })
        XCTAssertTrue(entries.contains {
            $0.category == .network &&
                $0.message.contains("Responses request payload") &&
                ($0.metadata["payload"]?.contains("\"model\"") ?? false)
        })
        XCTAssertTrue(entries.contains {
            $0.category == .network &&
                $0.message.contains("Responses response payload") &&
                $0.metadata["type"] == "response.completed" &&
                ($0.metadata["payload"]?.contains("\"id\":\"resp_retry\"") ?? false)
        })
        XCTAssertFalse(entries.contains {
            $0.category == .network &&
                $0.message.contains("Responses stream payload")
        })
    }

    func testBackendVerboseLoggingEmitsPayloadEntries() async throws {
        let buffer = RuntimeLogBuffer()
        let logging = AgentLoggingConfiguration(
            minimumLevel: .verbose,
            sink: RuntimeTestLogSink(buffer: buffer)
        )
        let backend = CodexResponsesBackend(
            configuration: CodexResponsesBackendConfiguration(
                logging: logging
            ),
            urlSession: makeTestURLSession()
        )
        let session = ChatGPTSession(
            accessToken: "access-token",
            refreshToken: "refresh-token",
            account: ChatGPTAccount(
                id: "workspace-123",
                email: "taylor@example.com",
                plan: .plus
            )
        )

        await TestURLProtocol.enqueue(.init(
            headers: ["Content-Type": "text/event-stream"],
            body: Data("""
            event: response.output_item.done
            data: {"type":"response.output_item.done","output_index":0,"item":{"id":"rs_verbose","type":"reasoning","content":[],"encrypted_content":"secret-encrypted-reasoning","summary":[]}}

            event: response.output_item.done
            data: {"type":"response.output_item.done","output_index":1,"item":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Done"}]}}

            event: response.completed
            data: {"type":"response.completed","response":{"id":"resp_verbose","usage":{"input_tokens":5,"input_tokens_details":{"cached_tokens":0},"output_tokens":2}}}

            """.utf8)
        ))

        let turnStream = try await backend.beginTurn(
            thread: AgentThread(id: "thread-verbose"),
            history: [],
            message: Request(text: "Hi"),
            instructions: "Resolved instructions",
            responseFormat: nil,
            streamedStructuredOutput: nil,
            tools: [],
            session: session
        )

        for try await _ in turnStream.events {}

        let entries = buffer.entries
        XCTAssertFalse(entries.contains {
            $0.metadata.values.contains { $0.contains("secret-encrypted-reasoning") }
        })
        XCTAssertTrue(entries.contains {
            $0.metadata["payload"]?.contains("<redacted; 26 characters>") == true
        })
        XCTAssertTrue(entries.contains {
            $0.level == .debug &&
                $0.category == .network &&
                $0.message.contains("Responses response payload") &&
                $0.metadata["type"] == "response.completed" &&
                ($0.metadata["payload"]?.contains("\"id\":\"resp_verbose\"") ?? false)
        })
        XCTAssertTrue(entries.contains {
            $0.level == .verbose &&
                $0.category == .network &&
                $0.message.contains("Responses stream payload") &&
            ($0.metadata["payload"]?.contains("\"type\":\"response.completed\"") ?? false)
        })
    }

    func testBackendFailureLogIncludesRetryDecisionMetadata() async throws {
        let buffer = RuntimeLogBuffer()
        let logging = AgentLoggingConfiguration(
            minimumLevel: .debug,
            sink: RuntimeTestLogSink(buffer: buffer)
        )
        let backend = CodexResponsesBackend(
            configuration: CodexResponsesBackendConfiguration(
                requestRetryPolicy: .init(
                    maxAttempts: 1,
                    initialBackoff: 0,
                    maxBackoff: 0,
                    jitterFactor: 0
                ),
                logging: logging
            ),
            urlSession: makeTestURLSession()
        )
        let session = ChatGPTSession(
            accessToken: "access-token",
            refreshToken: "refresh-token",
            account: ChatGPTAccount(
                id: "workspace-123",
                email: "taylor@example.com",
                plan: .plus
            )
        )

        await TestURLProtocol.enqueue(.init(
            body: Data(),
            error: URLError(.networkConnectionLost)
        ))

        let turnStream = try await backend.beginTurn(
            thread: AgentThread(id: "thread-retry-log"),
            history: [],
            message: Request(text: "Hi"),
            instructions: "Resolved instructions",
            responseFormat: nil,
            streamedStructuredOutput: nil,
            tools: [],
            session: session
        )

        await XCTAssertThrowsErrorAsync(try await drainLoggingTestEvents(turnStream.events))

        let failureEntry = try XCTUnwrap(buffer.entries.first {
            $0.category == .network &&
                $0.message.contains("Backend turn pass failed without retry")
        })
        XCTAssertEqual(failureEntry.metadata["attempt"], "1")
        XCTAssertEqual(failureEntry.metadata["max_attempts"], "1")
        XCTAssertEqual(failureEntry.metadata["has_visible_output"], "false")
        XCTAssertEqual(failureEntry.metadata["retryable_error"], "true")
        XCTAssertEqual(failureEntry.metadata["retry_blocked_by"], "max_attempts_reached")
    }
}

private final class RuntimeLogBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AgentLogEntry] = []

    var entries: [AgentLogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ entry: AgentLogEntry) {
        lock.lock()
        storage.append(entry)
        lock.unlock()
    }
}

private func drainLoggingTestEvents(_ events: AsyncThrowingStream<AgentBackendEvent, Error>) async throws {
    for try await _ in events {}
}

private struct RuntimeTestLogSink: AgentLogSink {
    let buffer: RuntimeLogBuffer

    func log(_ entry: AgentLogEntry) {
        buffer.append(entry)
    }
}
