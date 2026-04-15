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
        _ = try await runtime.signIn()
        let thread = try await runtime.createThread(title: "Logging")
        _ = try await runtime.sendMessage(
            UserMessageRequest(text: "Log this turn"),
            in: thread.id
        )

        let entries = buffer.entries
        XCTAssertTrue(entries.contains { $0.category == .auth && $0.message.contains("sign-in completed") })
        XCTAssertTrue(entries.contains { $0.category == .runtime && $0.message.contains("Thread created") })
        XCTAssertTrue(entries.contains { $0.category == .runtime && $0.message.contains("Starting streamed message") })
        XCTAssertTrue(entries.contains { $0.category == .persistence })
    }
}

extension CodexResponsesBackendTests {
    func testBackendLoggingEmitsRetryAndPayloadEntries() async throws {
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
            message: UserMessageRequest(text: "Hi"),
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
                $0.message.contains("Responses stream payload") &&
                ($0.metadata["payload"]?.contains("\"type\":\"response.completed\"") ?? false)
        })
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

private struct RuntimeTestLogSink: AgentLogSink {
    let buffer: RuntimeLogBuffer

    func log(_ entry: AgentLogEntry) {
        buffer.append(entry)
    }
}
