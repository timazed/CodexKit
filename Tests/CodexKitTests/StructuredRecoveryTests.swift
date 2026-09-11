@testable import CodexKit
import XCTest

final class StructuredRecoveryTests: XCTestCase {
    private var directory: URL!
    private var store: AgentStructuredRecoveryStore { .init(directory: directory) }
    private let created = "data: {\"type\":\"response.created\",\"sequence_number\":0,\"response\":{\"id\":\"original\"}}\n\n"
    private let delta = "data: {\"type\":\"response.output_text.delta\",\"sequence_number\":1,\"delta\":\"discard me\"}\n\n"
    private let message = "data: {\"type\":\"response.output_item.done\",\"sequence_number\":2,\"item\":{\"id\":\"message\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"{\\\"value\\\":\\\"ok\\\"}\"}]}}\n\n"
    private let completed = "data: {\"type\":\"response.completed\",\"sequence_number\":3,\"response\":{\"id\":\"completed\"}}\n\n"

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
    override func tearDown() {
        RecoveryProbeURLProtocol.endHeldConnection()
        try? FileManager.default.removeItem(at: directory)
    }

    private func runtime(provider: any AgentSessionProviding = RecoveryTestSession(),
        tools: [AgentRuntime.ToolRegistration] = []) throws -> AgentRuntime {
        try .init(configuration: .init(sessionProvider: provider,
            backend: CodexResponsesBackend(configuration: .init(enableWebSearch: true, enableImageGeneration: true,
                requestRetryPolicy: .init(maxAttempts: 9, initialBackoff: 0, maxBackoff: 0)),
                urlSession: RecoveryProbeURLProtocol.session()),
            approvalPresenter: AutoApprovalPresenter(), stateStore: InMemoryRuntimeStateStore(),
            turnLimits: .init(maximumDuration: 0.001), tools: tools))
    }

    private func prepare(_ runtime: AgentRuntime, maximumAttempts: Int = 3,
        expiresAt: Date? = nil) async throws -> AgentStructuredRecoveryHandle {
        let thread = try await runtime.createThread()
        return try await runtime.prepareStructuredRecovery(Request(text: "Synthetic", executionMode: .ephemeral),
            in: thread.id, response: RecoveryTestOutput.self, store: store,
            maximumAttempts: maximumAttempts, expiresAt: expiresAt)
    }

    func testBeforeAndMidOutputAndLostTerminalRecoverWithOneValidatedReplacement() async throws {
        for prefix in [created, created + delta, created + message] {
            RecoveryProbeURLProtocol.configure([.init(body: prefix), .init(body: message + completed)])
            let runtime = try runtime()
            let handle = try await prepare(runtime)
            let budget = RecoveryTestBudget(limit: 3)
            let output = try await runtime.sendRecovering(handle, response: RecoveryTestOutput.self, store: store) {
                await budget.reserve($0)
            }
            XCTAssertEqual(output.value, "ok")
            let calls = RecoveryProbeURLProtocol.requests
            XCTAssertEqual(calls.count, 2)
            XCTAssertEqual(calls.first?.httpBody, calls.last?.httpBody)
            XCTAssertNotEqual(calls.first?.value(forHTTPHeaderField: "x-client-request-id"),
                calls.last?.value(forHTTPHeaderField: "x-client-request-id"))
            let attempts = await budget.attempts
            XCTAssertEqual(attempts.map(\.number), [1, 2])
            XCTAssertEqual(attempts.map(\.reason), [.initial, .replacement])
            XCTAssertEqual(attempts.last?.previousFailure?.interruption?.responseID, "original")
            let status = try await runtime.structuredRecoveryStatus(handle, store: store)
            XCTAssertEqual(status.state, .completed)
            XCTAssertEqual(status.responseID, "completed")
            XCTAssertEqual(status.lastSequenceNumber, 3)
            let body = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(calls.first?.httpBody))
            XCTAssertEqual(body.objectValue?["tools"], .array([]))
            XCTAssertEqual(body.objectValue?["tool_choice"], .string("none"))
        }
    }

    func testNetworkLossAndTimeoutRetainTypedMetadataAndRecover() async throws {
        for code in [URLError.Code.networkConnectionLost, .timedOut] {
            RecoveryProbeURLProtocol.configure([.init(body: created + delta, holdOpen: true), .init(body: message + completed)])
            let runtime = try runtime()
            let handle = try await prepare(runtime)
            let budget = RecoveryTestBudget(limit: 3)
            let store = store
            let task = Task { try await runtime.sendRecovering(handle, response: RecoveryTestOutput.self, store: store) {
                await budget.reserve($0)
            } }
            try await waitForCursor(handle, 1)
            RecoveryProbeURLProtocol.endHeldConnection(code)
            let output = try await task.value
            XCTAssertEqual(output.value, "ok")
            let attempts = await budget.attempts
            XCTAssertEqual(attempts.last?.previousFailure?.interruption?.transportErrorCode, code.rawValue)
            XCTAssertEqual(attempts.last?.previousFailure?.interruption?.lastSequenceNumber, 1)
            XCTAssertEqual(attempts.last?.previousFailure?.interruption?.hasOutput, true)
        }
    }

    func testCompletedReceiptSurvivesColdRuntimeAndStoreReopenWithoutHTTP() async throws {
        RecoveryProbeURLProtocol.configure([.init(body: created + message + completed, holdOpen: true)])
        let first = try runtime()
        let handle = try await prepare(first)
        _ = try await first.sendRecovering(handle, response: RecoveryTestOutput.self, store: store) { _ in true }
        let encoded = try JSONEncoder().encode(handle)
        let restoredHandle = try JSONDecoder().decode(AgentStructuredRecoveryHandle.self, from: encoded)
        let reopened = try runtime()
        let output = try await reopened.sendRecovering(restoredHandle, response: RecoveryTestOutput.self,
            store: .init(directory: directory)) { _ in XCTFail("Completed receipt must not request authorization"); return false }
        XCTAssertEqual(output.value, "ok")
        XCTAssertEqual(RecoveryProbeURLProtocol.requests.count, 1)
        try await reopened.acknowledgeStructuredRecovery(handle, store: store)
        do {
            _ = try await reopened.sendRecovering(handle, response: RecoveryTestOutput.self, store: store) { _ in true }
            XCTFail("Missing receipt must not start a replacement")
        } catch { XCTAssertEqual(error as? AgentRecoveryError, .stateUnavailable) }
        XCTAssertEqual(RecoveryProbeURLProtocol.requests.count, 1)
    }

    func testHostDenialAndColdReopenPreserveAttemptCount() async throws {
        RecoveryProbeURLProtocol.configure([.init(body: created + delta), .init(body: message + completed)])
        let first = try runtime()
        let handle = try await prepare(first)
        do {
            _ = try await first.sendRecovering(handle, response: RecoveryTestOutput.self, store: store) { $0.number == 1 }
            XCTFail("Host denied replacement")
        } catch { XCTAssertEqual(error as? AgentRecoveryError, .attemptNotAuthorized) }
        XCTAssertEqual(RecoveryProbeURLProtocol.requests.count, 1)
        let reopened = try runtime()
        let output = try await reopened.sendRecovering(handle, response: RecoveryTestOutput.self, store: store) {
            XCTAssertEqual($0.number, 2); return true
        }
        XCTAssertEqual(output.value, "ok")
        XCTAssertEqual(RecoveryProbeURLProtocol.requests.count, 2)
    }

    func testBudgetExhaustionPersistsDespiteConfiguredNineSDKRetries() async throws {
        RecoveryProbeURLProtocol.configure(Array(repeating: .init(body: created), count: 5))
        let runtime = try runtime()
        let handle = try await prepare(runtime)
        do {
            _ = try await runtime.sendRecovering(handle, response: RecoveryTestOutput.self, store: store) { _ in true }
            XCTFail("Expected exhaustion")
        } catch { XCTAssertEqual((error as? AgentRuntimeError)?.interruption?.outcome, .disconnected) }
        XCTAssertEqual(RecoveryProbeURLProtocol.requests.count, 3)
        let reopened = try self.runtime()
        do {
            _ = try await reopened.sendRecovering(handle, response: RecoveryTestOutput.self, store: store) { _ in
                XCTFail("Exhausted budget cannot ask for more"); return true
            }
            XCTFail("Expected persistent exhaustion")
        } catch { XCTAssertEqual(error as? AgentRecoveryError, .attemptsExhausted) }
        XCTAssertEqual(RecoveryProbeURLProtocol.requests.count, 3)
    }

    func testAuthenticationReissueConsumesHostAndPersistentBudget() async throws {
        RecoveryProbeURLProtocol.configure([.init(body: "{}", statusCode: 401), .init(body: message + completed)])
        let runtime = try runtime()
        let handle = try await prepare(runtime)
        let budget = RecoveryTestBudget(limit: 3)
        _ = try await runtime.sendRecovering(handle, response: RecoveryTestOutput.self, store: store) { await budget.reserve($0) }
        let attempts = await budget.attempts
        XCTAssertEqual(attempts.map(\.reason), [.initial, .authenticationReissue])
        XCTAssertEqual(RecoveryProbeURLProtocol.requests.count, 2)
        let status = try await runtime.structuredRecoveryStatus(handle, store: store)
        XCTAssertEqual(status.attemptsUsed, 2)
    }

    func testQuotaExhaustionNeverConsumesReplacementBudget() async throws {
        let quota = #"{"error":{"code":"insufficient_quota","type":"insufficient_quota","message":"Quota exhausted"}}"#
        RecoveryProbeURLProtocol.configure([
            .init(body: quota, statusCode: 429),
            .init(body: message + completed)
        ])
        let runtime = try runtime()
        let handle = try await prepare(runtime)
        do {
            _ = try await runtime.sendRecovering(handle, response: RecoveryTestOutput.self, store: store) { _ in true }
            XCTFail("Quota exhaustion must not trigger replacement generation")
        } catch {
            XCTAssertEqual((error as? AgentRuntimeError)?.knownCode, .quotaExceeded)
            XCTAssertEqual((error as? AgentRuntimeError)?.http?.isQuotaExceeded, true)
        }
        XCTAssertEqual(RecoveryProbeURLProtocol.requests.count, 1)
        let status = try await runtime.structuredRecoveryStatus(handle, store: store)
        XCTAssertEqual(status.attemptsUsed, 1)
        XCTAssertEqual(status.state, .failed)
        let reopened = try self.runtime()
        do {
            _ = try await reopened.sendRecovering(handle, response: RecoveryTestOutput.self, store: store) { _ in
                XCTFail("Reopening a quota failure must not authorize a replacement")
                return true
            }
            XCTFail("Reopening must preserve the terminal quota failure")
        } catch {
            XCTAssertEqual(error as? AgentRecoveryError, .permanentlyFailed)
        }
        let reopenedStatus = try await reopened.structuredRecoveryStatus(handle, store: store)
        XCTAssertEqual(reopenedStatus.lastFailure?.knownCode, .quotaExceeded)
        XCTAssertEqual(reopenedStatus.lastFailure?.http?.isQuotaExceeded, true)
        XCTAssertEqual(reopenedStatus.attemptsUsed, 1)
        XCTAssertEqual(RecoveryProbeURLProtocol.requests.count, 1)
    }

    func testTaskCancellationSuspendsAndExplicitCancellationNeverReplays() async throws {
        RecoveryProbeURLProtocol.configure([.init(body: created + delta, holdOpen: true)])
        let runtime = try runtime()
        let handle = try await prepare(runtime)
        let store = store
        let task = Task { try await runtime.sendRecovering(handle, response: RecoveryTestOutput.self, store: store) { _ in true } }
        try await waitForCursor(handle, 1)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled") } catch { XCTAssertTrue(error is CancellationError) }
        let suspended = try await runtime.structuredRecoveryStatus(handle, store: store)
        XCTAssertEqual(suspended.availability, .suspended)
        XCTAssertEqual(suspended.attemptsUsed, 1)
        try await runtime.cancelStructuredRecovery(handle, store: store)
        let reopened = try self.runtime()
        do {
            _ = try await reopened.sendRecovering(handle, response: RecoveryTestOutput.self, store: store) { _ in true }
            XCTFail("Cancelled handle cannot restart")
        } catch { XCTAssertEqual(error as? AgentRecoveryError, .cancelled) }
        XCTAssertEqual(RecoveryProbeURLProtocol.requests.count, 1)
    }

    func testConcurrentOpenRejectedBeforeAuthorization() async throws {
        RecoveryProbeURLProtocol.configure([.init(body: created + delta, holdOpen: true)])
        let runtime = try runtime()
        let handle = try await prepare(runtime)
        let store = store
        let task = Task { try await runtime.sendRecovering(handle, response: RecoveryTestOutput.self, store: store) { _ in true } }
        try await waitForCursor(handle, 1)
        let other = try self.runtime()
        do {
            _ = try await other.sendRecovering(handle, response: RecoveryTestOutput.self, store: store) { _ in
                XCTFail("Concurrent open cannot authorize"); return true
            }
            XCTFail("Expected busy")
        } catch { XCTAssertEqual(error as? AgentRecoveryError, .busy) }
        task.cancel()
        _ = try? await task.value
        XCTAssertEqual(RecoveryProbeURLProtocol.requests.count, 1)
    }

    func testAccountChangeCannotReadReceiptOrStartReplacement() async throws {
        RecoveryProbeURLProtocol.configure([.init(body: message + completed)])
        let runtime = try runtime()
        let handle = try await prepare(runtime)
        _ = try await runtime.sendRecovering(handle, response: RecoveryTestOutput.self, store: store) { _ in true }
        let other = try self.runtime(provider: RecoveryTestSession(account: "different"))
        do {
            _ = try await other.sendRecovering(handle, response: RecoveryTestOutput.self, store: store) { _ in true }
            XCTFail("Account binding must be preserved")
        } catch { XCTAssertEqual(error as? ChatGPTSessionError, .accountChanged) }
        XCTAssertEqual(RecoveryProbeURLProtocol.requests.count, 1)
    }

    func testExpiredAndInvalidContractDoNotGenerate() async throws {
        RecoveryProbeURLProtocol.configure([])
        let runtime = try runtime()
        let expired = try await prepare(runtime, expiresAt: Date(timeIntervalSinceNow: -1))
        do {
            _ = try await runtime.sendRecovering(expired, response: RecoveryTestOutput.self, store: store) { _ in true }
            XCTFail("Expired")
        } catch { XCTAssertEqual(error as? AgentRecoveryError, .stateExpired) }
        let handle = try await prepare(runtime)
        do {
            _ = try await runtime.sendRecovering(handle, response: OtherRecoveryOutput.self, store: store) { _ in true }
            XCTFail("Wrong format")
        } catch { XCTAssertEqual(error as? AgentRecoveryError, .formatMismatch) }
        XCTAssertTrue(RecoveryProbeURLProtocol.requests.isEmpty)
    }

    func testProviderFailureIncompleteAndInvalidJSONNeverRetryOrSaveCompletion() async throws {
        let failures = ["data: {\"type\":\"response.failed\"}\n\n",
            "data: {\"type\":\"response.incomplete\"}\n\n", message.replacingOccurrences(of: "ok", with: "invalid") + completed]
        for body in failures {
            RecoveryProbeURLProtocol.configure([.init(body: body)])
            let runtime = try runtime()
            let handle = try await prepare(runtime)
            do {
                _ = try await runtime.sendRecovering(handle, response: RecoveryTestOutput.self, store: store) { _ in true }
                XCTFail("Expected failure")
            } catch {}
            let status = try await runtime.structuredRecoveryStatus(handle, store: store)
            XCTAssertEqual(status.state, .failed)
            XCTAssertEqual(RecoveryProbeURLProtocol.requests.count, 1)
            XCTAssertNil(try store.load(handle).completedPayload)
        }
    }

    private func waitForCursor(_ handle: AgentStructuredRecoveryHandle, _ cursor: Int) async throws {
        for _ in 0..<300 {
            if (try? store.load(handle).lastSequenceNumber) == cursor { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Transport never reached the expected cursor")
        throw AgentRecoveryError.stateUnavailable
    }

    func testUnexpectedToolCannotExecuteOrCauseReplacement() async throws {
        let call = "data: {\"type\":\"response.output_item.done\",\"sequence_number\":2,\"item\":{\"type\":\"function_call\",\"call_id\":\"effect\",\"name\":\"write\",\"arguments\":\"{}\"}}\n\n"
        RecoveryProbeURLProtocol.configure([.init(body: created + call + call + completed)])
        let counter = RecoveryToolCounter()
        let runtime = try runtime(tools: [.init(definition: .init(name: "write", description: "Effect",
            inputSchema: .object([:]), approvalPolicy: .automatic), executor: AnyToolExecutor { invocation, _ in
                await counter.increment()
                return .success(invocation: invocation, text: "written")
            })])
        let handle = try await prepare(runtime)
        do {
            _ = try await runtime.sendRecovering(handle, response: RecoveryTestOutput.self, store: store) { _ in true }
            XCTFail("Tools are forbidden")
        } catch { XCTAssertEqual((error as? AgentRuntimeError)?.interruption?.hasToolActivity, true) }
        let effects = await counter.count
        XCTAssertEqual(effects, 0)
        XCTAssertEqual(RecoveryProbeURLProtocol.requests.count, 1)
        let status = try await runtime.structuredRecoveryStatus(handle, store: store)
        XCTAssertEqual(status.state, .failed)
    }

    func testDeniedAuthenticationReissueDoesNotTransmitOrResetBudget() async throws {
        RecoveryProbeURLProtocol.configure([.init(body: "{}", statusCode: 401), .init(body: message + completed)])
        let runtime = try runtime()
        let handle = try await prepare(runtime)
        do {
            _ = try await runtime.sendRecovering(handle, response: RecoveryTestOutput.self, store: store) { $0.number == 1 }
            XCTFail("Reissue denied")
        } catch { XCTAssertEqual(error as? AgentRecoveryError, .attemptNotAuthorized) }
        let status = try await runtime.structuredRecoveryStatus(handle, store: store)
        XCTAssertEqual(status.attemptsUsed, 1)
        XCTAssertEqual(status.lastFailure?.http?.statusCode, 401)
        XCTAssertEqual(RecoveryProbeURLProtocol.requests.count, 1)
    }

    func testAccountSwitchDuringAuthorizationPreventsTransmission() async throws {
        RecoveryProbeURLProtocol.configure([])
        let provider = MutableRecoverySession()
        let runtime = try runtime(provider: provider)
        let handle = try await prepare(runtime)
        do {
            _ = try await runtime.sendRecovering(handle, response: RecoveryTestOutput.self, store: store) { _ in
                await provider.switchAccount(); return true
            }
            XCTFail("Account changed")
        } catch { XCTAssertEqual(error as? ChatGPTSessionError, .accountChanged) }
        XCTAssertTrue(RecoveryProbeURLProtocol.requests.isEmpty)
    }

    func testCredentialRotationWhileHostAuthorizesUsesFreshToken() async throws {
        RecoveryProbeURLProtocol.configure([.init(body: message + completed)])
        let provider = MutableRecoverySession()
        let runtime = try runtime(provider: provider)
        let handle = try await prepare(runtime)
        _ = try await runtime.sendRecovering(handle, response: RecoveryTestOutput.self, store: store) { _ in
            await provider.rotateToken(); return true
        }
        XCTAssertEqual(RecoveryProbeURLProtocol.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer rotated")
        let recordData = try Data(contentsOf: directory.appendingPathComponent(handle.id.uuidString + ".json"))
        XCTAssertFalse(String(decoding: recordData, as: UTF8.self).contains("rotated"), "Credentials must never enter recovery storage")
    }

    func testExpiryWhileHostWaitsPreventsNewAttemptWithoutTimingOutGeneration() async throws {
        RecoveryProbeURLProtocol.configure([])
        let runtime = try runtime()
        let handle = try await prepare(runtime, expiresAt: Date(timeIntervalSinceNow: 0.1))
        do {
            _ = try await runtime.sendRecovering(handle, response: RecoveryTestOutput.self, store: store) { _ in
                try await Task.sleep(for: .milliseconds(150)); return true
            }
            XCTFail("Expired permission must not transmit")
        } catch { XCTAssertEqual(error as? AgentRecoveryError, .stateExpired) }
        XCTAssertTrue(RecoveryProbeURLProtocol.requests.isEmpty)
    }

    func testColdInterruptedProcessRequiresAuthorizationAndRetainsCursor() async throws {
        RecoveryProbeURLProtocol.configure([.init(body: message + completed)])
        let first = try runtime()
        let handle = try await prepare(first)
        // Represents a process killed after recording an HTTP attempt and cursor, before an outcome.
        var checkpoint = try store.load(handle)
        checkpoint.state = .running
        checkpoint.attemptsUsed = 1
        checkpoint.responseID = "crashed-response"
        checkpoint.lastSequenceNumber = 7
        try store.save(checkpoint)
        let reopened = try runtime()
        _ = try await reopened.sendRecovering(handle, response: RecoveryTestOutput.self, store: store) {
            XCTAssertEqual($0.number, 2)
            XCTAssertEqual($0.reason, .replacement)
            XCTAssertEqual($0.previousResponseID, "crashed-response")
            XCTAssertEqual($0.previousSequenceNumber, 7)
            return true
        }
        XCTAssertEqual(RecoveryProbeURLProtocol.requests.count, 1)
    }

    func testCorruptReceiptNeverStartsReplacement() async throws {
        RecoveryProbeURLProtocol.configure([.init(body: message + completed)])
        let runtime = try runtime()
        let handle = try await prepare(runtime)
        _ = try await runtime.sendRecovering(handle, response: RecoveryTestOutput.self, store: store) { _ in true }
        var record = try store.load(handle)
        record.completedPayload = Data("{\"value\":\"invalid\"}".utf8)
        try store.save(record)
        do {
            _ = try await runtime.sendRecovering(handle, response: RecoveryTestOutput.self, store: store) { _ in
                XCTFail("Invalid saved output must not authorize new generation"); return true
            }
            XCTFail("Receipt must be revalidated")
        } catch { XCTAssertEqual((error as? AgentRuntimeError)?.code, "structured_output_schema_invalid") }
        XCTAssertEqual(RecoveryProbeURLProtocol.requests.count, 1)
    }
}

private struct RecoveryTestOutput: AgentStructuredOutput {
    let value: String
    static let responseFormat = AgentStructuredOutputFormat(name: "recovery-test",
        schema: .object(properties: ["value": .string(enum: ["ok"])], required: ["value"]))
}
private struct OtherRecoveryOutput: AgentStructuredOutput {
    let value: String
    static let responseFormat = AgentStructuredOutputFormat(name: "other", schema: .string())
}
private actor RecoveryTestBudget {
    let limit: Int
    var attempts: [AgentRecoveryAttempt] = []
    init(limit: Int) { self.limit = limit }
    func reserve(_ attempt: AgentRecoveryAttempt) -> Bool {
        guard attempts.count < limit else { return false }
        attempts.append(attempt)
        return true
    }
}
private struct RecoveryTestSession: AgentSessionProviding {
    var account = "recovery-test"
    func currentSession() async -> ChatGPTSession? {
        .init(accessToken: "synthetic-token", account: .init(id: account, email: "test@example.com", plan: .unknown))
    }
    func recoverUnauthorizedSession(previousAccessToken: String?) async throws -> ChatGPTSession {
        .init(accessToken: "synthetic-renewed-token", account: .init(id: account, email: "test@example.com", plan: .unknown))
    }
}

private actor RecoveryToolCounter {
    var count = 0
    func increment() { count += 1 }
}
private actor MutableRecoverySession: AgentSessionProviding {
    var account = "original"
    var token = "synthetic"
    func switchAccount() { account = "changed" }
    func rotateToken() { token = "rotated" }
    func currentSession() async -> ChatGPTSession? {
        .init(accessToken: token, account: .init(id: account, email: "test@example.com", plan: .unknown))
    }
}
