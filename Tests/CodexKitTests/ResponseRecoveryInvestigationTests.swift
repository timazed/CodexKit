@testable import CodexKit
import XCTest

/// Transport behavior, including local reliability improvements. These tests do not imply provider resumption.
final class ResponseRecoveryInvestigationTests: XCTestCase {
    override func tearDown() async throws { RecoveryProbeURLProtocol.endHeldConnection() }

    private let created = "data: {\"type\":\"response.created\",\"sequence_number\":0,\"response\":{\"id\":\"resp_original\"}}\n\n"
    private let delta = "data: {\"type\":\"response.output_text.delta\",\"sequence_number\":1,\"delta\":\"Hel\"}\n\n"
    private let completed = "data: {\"type\":\"response.completed\",\"sequence_number\":3,\"response\":{\"id\":\"resp_original\"}}\n\n"
    private let message = "data: {\"type\":\"response.output_item.done\",\"sequence_number\":2,\"item\":{\"id\":\"message\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"{\\\"value\\\":\\\"ok\\\"}\"}]}}\n\n"
    private let tool = "data: {\"type\":\"response.output_item.done\",\"sequence_number\":2,\"item\":{\"type\":\"function_call\",\"call_id\":\"side-effect\",\"name\":\"write\",\"arguments\":\"{}\"}}\n\n"

    private func backend(attempts: Int = 1) -> CodexResponsesBackend {
        .init(configuration: .init(enableWebSearch: false, enableImageGeneration: false,
            requestRetryPolicy: .init(maxAttempts: attempts, initialBackoff: 0, maxBackoff: 0, jitterFactor: 0)),
            urlSession: RecoveryProbeURLProtocol.session())
    }

    private func begin(_ backend: CodexResponsesBackend) async throws -> AgentTurnStream {
        try await backend.beginTurn(thread: .init(id: "thread"), history: [],
            message: Request(text: "Synthetic").correlated(with: "host-request"), instructions: "Help",
            responseFormat: nil, streamedStructuredOutput: nil, tools: [], session: demoSession())
    }

    private func runtime(store: any RuntimeStateStoring = InMemoryRuntimeStateStore(),
                         attempts: Int = 1, tools: [AgentRuntime.ToolRegistration] = []) throws -> AgentRuntime {
        try .init(configuration: .init(sessionProvider: RecoveryProbeSessionProvider(), backend: backend(attempts: attempts),
            approvalPresenter: AutoApprovalPresenter(), stateStore: store,
            turnLimits: .init(maximumToolCalls: 8, maximumDuration: nil), tools: tools))
    }

    func testBeforeOutputRetryIsIdenticalPOSTWithoutRecoveryCursor() async throws {
        RecoveryProbeURLProtocol.configure([.init(body: created), .init(body: message + completed)])
        let stream = try await begin(backend(attempts: 2))
        for try await _ in stream.events {}
        let requests = RecoveryProbeURLProtocol.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.map(\.httpMethod), ["POST", "POST"])
        XCTAssertEqual(requests.first?.httpBody, requests.last?.httpBody)
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "x-client-request-id"), "thread")
        XCTAssertNil(requests.last?.value(forHTTPHeaderField: "Last-Event-ID"))
        XCTAssertNil(requests.last?.url?.query)
        let body = try XCTUnwrap(requests.last?.httpBody)
        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("resp_original"))
    }

    func testDisabledRetryStopsAfterCreatedAndPreservesDiagnosticResponseID() async throws {
        RecoveryProbeURLProtocol.configure([.init(body: created)])
        let stream = try await begin(backend())
        do {
            for try await _ in stream.events {}
            XCTFail("Expected disconnect")
        } catch let error as AgentRuntimeError {
            XCTAssertEqual(error.code, "responses_stream_disconnected")
            XCTAssertEqual(error.retry?.maximumAttempts, 1)
            XCTAssertEqual(error.retry?.safety, .beforeOutput)
            let encoded = try JSONEncoder().encode(error)
            XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains("resp_original"))
            XCTAssertEqual(error.interruption?.lastSequenceNumber, 0)
        }
        XCTAssertEqual(RecoveryProbeURLProtocol.requests.count, 1)
    }

    func testAcknowledgedDeltaThenNetworkLossOrTimeoutNeverReplays() async throws {
        for code in [URLError.Code.networkConnectionLost, .timedOut] {
            RecoveryProbeURLProtocol.configure([.init(body: created + delta, holdOpen: true)])
            let stream = try await begin(backend(attempts: 3))
            var text = ""
            do {
                for try await event in stream.events {
                    if case let .assistantMessageDelta(_, _, value) = event {
                        text += value
                        RecoveryProbeURLProtocol.endHeldConnection(code)
                    }
                }
                XCTFail("Expected transport failure")
            } catch {
                let failure = try XCTUnwrap(error as? AgentRuntimeError)
                XCTAssertEqual(failure.interruption?.transportErrorDomain, NSURLErrorDomain)
                XCTAssertEqual(failure.interruption?.transportErrorCode, code.rawValue)
                XCTAssertEqual(failure.retry?.safety, .outputAlreadyEmitted)
            }
            XCTAssertEqual(text, "Hel")
            XCTAssertEqual(RecoveryProbeURLProtocol.requests.count, 1)
        }
    }

    func testLostTerminalEventDoesNotReturnEvenValidStructuredItem() async throws {
        RecoveryProbeURLProtocol.configure([.init(body: created + message)])
        let runtime = try runtime()
        let thread = try await runtime.createThread()
        do {
            _ = try await runtime.send(Request(text: "Synthetic", executionMode: .ephemeral), in: thread.id, response: RecoveryProbeOutput.self)
            XCTFail("An output item is not proof of response completion")
        } catch {
            XCTAssertEqual((error as? AgentRuntimeError)?.code, "responses_stream_disconnected")
        }
        XCTAssertEqual(RecoveryProbeURLProtocol.requests.count, 1)
    }

    func testCompletedResponseDoesNotWaitForSocketEOF() async throws {
        RecoveryProbeURLProtocol.configure([.init(body: created + message + completed, holdOpen: true)])
        let runtime = try runtime()
        let thread = try await runtime.createThread()
        let value = try await runtime.send(Request(text: "Synthetic", executionMode: .ephemeral), in: thread.id, response: RecoveryProbeOutput.self)
        XCTAssertEqual(value.value, "ok")
        RecoveryProbeURLProtocol.endHeldConnection(.networkConnectionLost)
        XCTAssertEqual(RecoveryProbeURLProtocol.requests.count, 1)
    }

    func testRepeatedSequenceNumbersDoNotRepeatDeltas() async throws {
        RecoveryProbeURLProtocol.configure([.init(body: created + delta + delta + message + completed)])
        let stream = try await begin(backend())
        var text = ""
        for try await event in stream.events {
            if case let .assistantMessageDelta(_, _, value) = event { text += value }
        }
        XCTAssertEqual(text, "Hel")
    }

    func testProviderCompletionStillRequiresValidStructuredResult() async throws {
        let invalid = message.replacingOccurrences(of: "ok", with: "invalid")
        RecoveryProbeURLProtocol.configure([.init(body: created + invalid + completed)])
        let runtime = try runtime()
        let thread = try await runtime.createThread()
        do {
            _ = try await runtime.send(Request(text: "Synthetic", executionMode: .ephemeral),
                in: thread.id, response: RecoveryProbeOutput.self)
            XCTFail("Completed JSON must satisfy the declared schema")
        } catch { XCTAssertEqual((error as? AgentRuntimeError)?.code, "structured_output_schema_invalid") }
        XCTAssertEqual(RecoveryProbeURLProtocol.requests.count, 1)
    }

    func testColdReopenRestoresConversationButNotEphemeralGeneration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("runtime.json")
        RecoveryProbeURLProtocol.configure([.init(body: created + message)])
        let first = try runtime(store: FileRuntimeStateStore(url: url))
        let thread = try await first.createThread()
        do { _ = try await first.send(Request(text: "Synthetic", executionMode: .ephemeral), in: thread.id, response: RecoveryProbeOutput.self) }
        catch { XCTAssertEqual((error as? AgentRuntimeError)?.code, "responses_stream_disconnected") }
        let second = try runtime(store: FileRuntimeStateStore(url: url))
        _ = try await second.restore()
        _ = try await second.resumeThread(id: thread.id)
        let messages = await second.messages(for: thread.id)
        XCTAssertTrue(messages.isEmpty)
        XCTAssertEqual(RecoveryProbeURLProtocol.requests.count, 1, "Reopening does not reconnect")
        RecoveryProbeURLProtocol.configure([.init(body: message + completed)])
        _ = try await second.send(Request(text: "Synthetic", executionMode: .ephemeral), in: thread.id, response: RecoveryProbeOutput.self)
        XCTAssertEqual(RecoveryProbeURLProtocol.requests.first?.httpMethod, "POST")
    }

    func testExplicitCancellationAfterOutputDoesNotRetry() async throws {
        RecoveryProbeURLProtocol.configure([.init(body: created + delta, holdOpen: true)])
        let stream = try await begin(backend(attempts: 3))
        var sawDelta = false
        var completions = 0
        do {
            for try await event in stream.events {
                if case .assistantMessageDelta = event { sawDelta = true; stream.interrupt() }
                if case .turnCompleted = event { completions += 1 }
            }
        } catch { XCTAssertTrue(error is CancellationError || (error as NSError).code == URLError.cancelled.rawValue) }
        XCTAssertTrue(sawDelta)
        XCTAssertEqual(completions, 0)
        XCTAssertEqual(RecoveryProbeURLProtocol.requests.count, 1)
    }

    func testCompletedToolEffectBeforeDisconnectIsNotAutomaticallyReplayed() async throws {
        RecoveryProbeURLProtocol.configure([.init(body: created + tool, holdOpen: true)])
        let counter = RecoveryEffectCounter()
        let runtime = try runtime(attempts: 3, tools: [.init(definition: .init(name: "write", description: "Synthetic effect",
            inputSchema: .object([:]), approvalPolicy: .automatic), executor: AnyToolExecutor { invocation, _ in
                await counter.increment()
                return .success(invocation: invocation, text: "written")
            })])
        let thread = try await runtime.createThread()
        let stream = try await runtime.stream(Request(text: "Synthetic", executionMode: .ephemeral), in: thread.id)
        do {
            for try await event in stream {
                if case .toolCallFinished = event { RecoveryProbeURLProtocol.endHeldConnection(.networkConnectionLost) }
            }
            XCTFail("Expected disconnect")
        } catch {}
        let count = await counter.count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(RecoveryProbeURLProtocol.requests.count, 1)
    }

    func testRepeatedToolEventDoesNotRepeatEphemeralSideEffect() async throws {
        let repeated = tool.replacingOccurrences(of: "\"sequence_number\":2", with: "\"sequence_number\":3")
        let terminal = completed.replacingOccurrences(of: "\"sequence_number\":3", with: "\"sequence_number\":4")
        RecoveryProbeURLProtocol.configure([.init(body: created + tool + repeated + terminal), .init(body: message + completed)])
        let counter = RecoveryEffectCounter()
        let runtime = try runtime(tools: [.init(definition: .init(name: "write", description: "Synthetic effect",
            inputSchema: .object([:]), approvalPolicy: .automatic), executor: AnyToolExecutor { invocation, _ in
                await counter.increment()
                return .success(invocation: invocation, text: "written")
            })])
        let thread = try await runtime.createThread()
        _ = try await runtime.send(Request(text: "Synthetic", executionMode: .ephemeral), in: thread.id)
        let count = await counter.count
        XCTAssertEqual(count, 1, "Deduplication is local to this turn; recovery forbids tools across requests")
    }

    func testProviderFailureAndIncompleteAreNotDisconnections() async throws {
        for (event, code) in [("response.failed", "responses_stream_failed"), ("response.incomplete", "responses_stream_incomplete")] {
            RecoveryProbeURLProtocol.configure([.init(body: "data: {\"type\":\"\(event)\",\"response\":{\"id\":\"resp_original\"}}\n\n")])
            let stream = try await begin(backend(attempts: 3))
            do { for try await _ in stream.events {}; XCTFail("Expected failure") }
            catch let error as AgentRuntimeError {
                XCTAssertEqual(error.code, code)
                XCTAssertEqual(error.retry?.isRetryable, false)
            }
            XCTAssertEqual(RecoveryProbeURLProtocol.requests.count, 1)
        }
    }
}

private struct RecoveryProbeSessionProvider: AgentSessionProviding {
    func currentSession() async -> ChatGPTSession? { demoSession() }
}

private struct RecoveryProbeOutput: AgentStructuredOutput {
    let value: String
    static let responseFormat = AgentStructuredOutputFormat(name: "probe",
        schema: .object(properties: ["value": .string(enum: ["ok"])], required: ["value"], additionalProperties: false))
}

private actor RecoveryEffectCounter {
    var count = 0
    func increment() { count += 1 }
}
