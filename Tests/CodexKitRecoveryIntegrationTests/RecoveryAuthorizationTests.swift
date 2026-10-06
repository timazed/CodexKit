import CodexKit
import Foundation
import RecoveryIntegrationSupport
import XCTest

@MainActor
final class RecoveryAuthorizationTests: XCTestCase {
    private var directory: URL!
    private var store: AgentStructuredRecoveryStore { .init(directory: directory) }

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() async throws {
        FixtureTransport.releaseHeld()
        try? FileManager.default.removeItem(at: directory)
    }

    private func prepare(_ runtime: AgentRuntime, maximumAttempts: Int = 3) async throws -> AgentStructuredRecoveryHandle {
        let thread = try await runtime.createThread()
        return try await runtime.prepareStructuredRecovery(.init(text: "news", executionMode: .ephemeral),
            in: thread.id, response: FixtureOutput.self, store: store, maximumAttempts: maximumAttempts,
            retryPolicy: .init(backoff: .init(initialBackoff: 0, maxBackoff: 0), retriesInvalidStructuredOutput: true))
    }

    func testAuthorizationErrorsEscapeWithoutRetryOrCredentialRenewal() async throws {
        let failures = [
            AgentRuntimeError(code: .responsesTransportError, message: "Host transport failed",
                interruption: .init(outcome: .disconnected)),
            AgentRuntimeError(code: .structuredOutputSchemaInvalid, message: "Host response invalid"),
            AgentRuntimeError(code: .unauthorized, message: "Host authorization rejected", http: .init(statusCode: 401))
        ]
        for failure in failures {
            FixtureTransport.configure(["news": [.complete("resumed")]])
            let session = FixtureSession()
            let runtime = try fixtureRuntime(session: session)
            let handle = try await prepare(runtime, maximumAttempts: 1)
            let authorization = FailingRecoveryAuthorization(failure: failure)
            do {
                _ = try await runtime.sendRecovering(handle, response: FixtureOutput.self, store: store) {
                    try await authorization.authorize($0)
                }
                XCTFail("The host's error must reach the caller")
            } catch { XCTAssertEqual(error as? AgentRuntimeError, failure) }

            let calls = await authorization.calls
            let renewals = await session.renewals
            XCTAssertEqual(calls.count, 1)
            XCTAssertEqual(renewals, 0, "A host callback's 401 is not a provider authentication failure")
            XCTAssertEqual(FixtureTransport.generationCount, 0)
            let status = try await runtime.structuredRecoveryStatus(handle, store: store)
            XCTAssertEqual(status.state, .interrupted)
            XCTAssertEqual(status.attemptsUsed, 0)
            XCTAssertNil(status.nextAttemptAt)
            XCTAssertNil(status.blocker)
            XCTAssertNil(status.lastFailure, "Host callback errors must not replace provider failure diagnostics")

            let pendingID = try XCTUnwrap(calls.first?.id)
            let reopened = try fixtureRuntime(session: session)
            let output = try await reopened.sendRecovering(handle, response: FixtureOutput.self, store: store) {
                XCTAssertEqual($0.id, pendingID)
                XCTAssertEqual($0.number, 1)
                return true
            }
            XCTAssertEqual(output.value, "resumed")
            XCTAssertEqual(FixtureTransport.generationCount, 1)
        }
    }

    func testAuthorizationFailureDuringAuthenticationReissueStopsWithOriginalBudget() async throws {
        FixtureTransport.configure(["news": [.http(401, [:]), .complete("resumed")]])
        let session = FixtureSession()
        let runtime = try fixtureRuntime(session: session)
        let handle = try await prepare(runtime)
        let failure = AgentRuntimeError(code: .responsesTransportError, message: "Host unavailable",
            interruption: .init(outcome: .disconnected))
        let authorization = FailingRecoveryAuthorization(failure: failure, initialApprovals: 1)
        do {
            _ = try await runtime.sendRecovering(handle, response: FixtureOutput.self, store: store) {
                try await authorization.authorize($0)
            }
            XCTFail("An authorization error must stop the authentication reissue")
        } catch { XCTAssertEqual(error as? AgentRuntimeError, failure) }

        let calls = await authorization.calls
        let renewals = await session.renewals
        XCTAssertEqual(calls.map(\.number), [1, 2])
        XCTAssertEqual(renewals, 1)
        XCTAssertEqual(FixtureTransport.generationCount, 1)
        let status = try await runtime.structuredRecoveryStatus(handle, store: store)
        XCTAssertEqual(status.state, .interrupted)
        XCTAssertEqual(status.attemptsUsed, 1)
        XCTAssertNil(status.nextAttemptAt)
        XCTAssertNil(status.blocker)
        XCTAssertEqual(status.lastFailure?.http?.statusCode, 401)

        let pendingID = try XCTUnwrap(calls.last?.id)
        let reopened = try fixtureRuntime(session: session)
        _ = try await reopened.sendRecovering(handle, response: FixtureOutput.self, store: store) {
            XCTAssertEqual($0.id, pendingID)
            XCTAssertEqual($0.number, 2)
            XCTAssertEqual($0.reason, .authenticationReissue)
            return true
        }
        XCTAssertEqual(FixtureTransport.generationCount, 2)
    }

    func testAuthorizationCancellationSuspendsWithoutSpendingAttempt() async throws {
        FixtureTransport.configure(["news": [.complete("resumed")]])
        let runtime = try fixtureRuntime()
        let handle = try await prepare(runtime)
        do {
            _ = try await runtime.sendRecovering(handle, response: FixtureOutput.self, store: store) { _ in
                throw CancellationError()
            }
            XCTFail("Cancellation must escape")
        } catch { XCTAssertTrue(error is CancellationError) }
        let status = try await runtime.structuredRecoveryStatus(handle, store: store)
        XCTAssertEqual(status.state, .suspended)
        XCTAssertEqual(status.attemptsUsed, 0)
        XCTAssertEqual(FixtureTransport.generationCount, 0)
        _ = try await runtime.sendRecovering(handle, response: FixtureOutput.self, store: store) { _ in true }
        XCTAssertEqual(FixtureTransport.generationCount, 1)
    }
}

private actor FailingRecoveryAuthorization {
    let failure: AgentRuntimeError
    let initialApprovals: Int
    var calls: [AgentRecoveryAttempt] = []

    init(failure: AgentRuntimeError, initialApprovals: Int = 0) {
        self.failure = failure
        self.initialApprovals = initialApprovals
    }

    func authorize(_ attempt: AgentRecoveryAttempt) throws -> Bool {
        calls.append(attempt)
        if calls.count <= initialApprovals { return true }
        // Keep the regression bounded even if the implementation starts looping again.
        guard calls.count <= initialApprovals + 5 else { return false }
        throw failure
    }
}
