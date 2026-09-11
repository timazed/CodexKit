import CodexKit
import Foundation
import RecoveryIntegrationSupport
import XCTest

@MainActor
final class RecoveryIntegrationTests: XCTestCase {
    var directory: URL!
    var store: AgentStructuredRecoveryStore { .init(directory: directory.appendingPathComponent("receipts")) }
    let noBackoff = AgentRecoveryRetryPolicy(backoff: .init(initialBackoff: 0, maxBackoff: 0))
    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
    override func tearDown() async throws {
        FixtureTransport.releaseHeld()
        try? FileManager.default.removeItem(at: directory)
    }
    func prepare(_ runtime: AgentRuntime, purpose: String = "news", attempts: Int = 3,
        expiry: Date? = nil, policy: AgentRecoveryRetryPolicy? = nil) async throws -> AgentStructuredRecoveryHandle {
        let thread = try await runtime.createThread()
        var request = Request(text: purpose, executionMode: .ephemeral)
        request.selectionPurpose = purpose
        return try await runtime.prepareStructuredRecovery(request, in: thread.id, response: FixtureOutput.self,
            store: store, maximumAttempts: attempts, expiresAt: expiry, retryPolicy: policy ?? noBackoff,
            scope: "campaign", hostJobID: purpose, inputRevision: "1", contractVersion: "1")
    }
    func waitUntil(_ predicate: @escaping @Sendable () async throws -> Bool) async throws {
        for _ in 0..<500 {
            if try await predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The fixture did not reach its synchronization point")
        throw FixtureHostStore.HostError.inapplicable
    }

    func testIndependentJobsExhaustionManualRetryAndIdempotentCommits() async throws {
        FixtureTransport.configure(["briefing": [.complete("briefing")], "summary": [.complete("summary")],
                                    "news": [.disconnect, .disconnect, .disconnect, .complete("news")]])
        let selector = PurposeSelector()
        let runtime = try fixtureRuntime(selector: selector, maximumDuration: 0.001)
        let host = try FixtureHostStore(directory: directory)
        let receipts = store
        var handles: [String: AgentStructuredRecoveryHandle] = [:]
        for purpose in ["briefing", "summary", "news"] {
            let handle = try await prepare(runtime, purpose: purpose)
            handles[purpose] = handle
            try await host.register(purpose, handle: handle)
        }
        await selector.changeModel("gpt-5.5")
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (purpose, handle) in handles {
                group.addTask {
                    do {
                        let output = try await runtime.sendRecovering(handle, response: FixtureOutput.self, store: receipts) { _ in true }
                        try await host.commit(output, jobID: purpose)
                    } catch {
                        guard purpose == "news", (error as? AgentRuntimeError)?.interruption?.outcome == .disconnected else { throw error }
                    }
                }
            }
            try await group.waitForAll()
        }
        XCTAssertEqual(FixtureTransport.generationCount, 5)
        let original = try XCTUnwrap(handles["news"])
        let exhausted = try await runtime.structuredRecoveryStatus(original, store: receipts)
        XCTAssertEqual(exhausted.availability, .exhausted)
        XCTAssertEqual(exhausted.attemptsUsed, 3)
        let action = UUID()
        let retry = try await runtime.retryStructuredRecovery(original, retryActionID: action, store: receipts)
        let repeated = try await runtime.retryStructuredRecovery(original, retryActionID: action, store: receipts)
        XCTAssertEqual(retry, repeated)
        do {
            _ = try await runtime.retryStructuredRecovery(original, retryActionID: UUID(), store: receipts)
            XCTFail("A second retry tap must not create another budget")
        } catch { XCTAssertEqual(error as? AgentRecoveryError, .retryAlreadyCreated) }
        try await host.register("news", handle: retry)
        let news = try await runtime.sendRecovering(retry, response: FixtureOutput.self, store: receipts) { _ in true }
        try await host.commit(news, jobID: "news")
        handles["news"] = retry
        let reopened = try fixtureRuntime(selector: RejectingSelector())
        for (purpose, handle) in handles {
            let output = try await reopened.sendRecovering(handle, response: FixtureOutput.self, store: receipts) { _ in
                XCTFail("Saved completion cannot authorize a generation"); return false
            }
            let applied = try await host.commit(output, jobID: purpose)
            XCTAssertFalse(applied)
            let job = await host.job(purpose)
            XCTAssertEqual(job?.commitCount, 1)
            try await reopened.acknowledgeStructuredRecovery(handle, store: receipts)
            try await reopened.acknowledgeStructuredRecovery(handle, store: receipts)
        }
        XCTAssertEqual(FixtureTransport.generationCount, 6)
        let selectedPurposes = await selector.purposes
        XCTAssertEqual(selectedPurposes.count, 3)
        let captures = FixtureTransport.captures.filter { $0.purpose == "news" }
        XCTAssertEqual(captures.count, 4)
        XCTAssertTrue(captures.allSatisfy { $0.body == captures[0].body && $0.model == "gpt-5.6-sol" && $0.effort == "high" })
        XCTAssertEqual(Set(FixtureTransport.captures.compactMap(\.requestID)).count, 6)
    }

    func testTaskCancellationSuspendsAndReopeningKeepsFrozenConfiguration() async throws {
        FixtureTransport.configure(["news": [.hold, .complete("recovered")]])
        let selector = PurposeSelector()
        let runtime = try fixtureRuntime(selector: selector)
        let handle = try await prepare(runtime)
        let receipts = store
        let task = Task { try await runtime.sendRecovering(handle, response: FixtureOutput.self, store: receipts) { _ in true } }
        try await waitUntil { try await runtime.structuredRecoveryStatus(handle, store: receipts).lastSequenceNumber == 1 }
        let active = try await runtime.structuredRecoveryStatus(handle, store: receipts)
        XCTAssertEqual(active.state, .running)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled lifecycle returned output") }
        catch { XCTAssertTrue(error is CancellationError) }
        let suspended = try await runtime.structuredRecoveryStatus(handle, store: receipts)
        XCTAssertEqual(suspended.state, .suspended)
        XCTAssertEqual(suspended.attemptsUsed, 1)
        do {
            _ = try await runtime.retryStructuredRecovery(handle, retryActionID: UUID(), store: receipts)
            XCTFail("Suspension must not reset a remaining budget")
        } catch { XCTAssertEqual(error as? AgentRecoveryError, .retryNotAllowed) }
        let reopened = try fixtureRuntime(selector: RejectingSelector())
        let output = try await reopened.sendRecovering(handle, response: FixtureOutput.self, store: receipts) { attempt in
            XCTAssertEqual(attempt.number, 2); return true
        }
        XCTAssertEqual(output.value, "recovered")
        XCTAssertEqual(FixtureTransport.generationCount, 2)
        XCTAssertEqual(FixtureTransport.captures.first?.body, FixtureTransport.captures.last?.body)
    }

    func testPermanentCancellationFromAnotherRuntimeIsTerminal() async throws {
        FixtureTransport.configure(["news": [.hold, .complete("must-not-publish")]])
        let runtime = try fixtureRuntime()
        let other = try fixtureRuntime()
        let handle = try await prepare(runtime)
        let receipts = store
        let task = Task { try await runtime.sendRecovering(handle, response: FixtureOutput.self, store: receipts) { _ in true } }
        try await waitUntil { try await other.structuredRecoveryStatus(handle, store: receipts).lastSequenceNumber == 1 }
        try await other.cancelStructuredRecovery(handle, store: receipts)
        do { _ = try await task.value; XCTFail("Permanently cancelled operation returned output") }
        catch { XCTAssertTrue(error is CancellationError) }
        do { _ = try await other.sendRecovering(handle, response: FixtureOutput.self, store: receipts) { _ in true }; XCTFail() }
        catch { XCTAssertEqual(error as? AgentRecoveryError, .cancelled) }
        let status = try await other.structuredRecoveryStatus(handle, store: receipts)
        XCTAssertEqual(status.availability, .permanentlyCancelled)
        XCTAssertEqual(FixtureTransport.generationCount, 1)
    }

    func testSuspensionDuringAuthorizationReusesPendingReservationID() async throws {
        FixtureTransport.configure(["news": [.complete("resumed")]])
        let runtime = try fixtureRuntime()
        let handle = try await prepare(runtime)
        let receipts = store
        let gate = AuthorizationGate()
        let task = Task { try await runtime.sendRecovering(handle, response: FixtureOutput.self, store: receipts) { attempt in
            await gate.hold(attempt.id); return true
        } }
        try await waitUntil { await gate.entered }
        try await runtime.suspendStructuredRecovery(handle, store: receipts)
        await gate.release()
        do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(FixtureTransport.generationCount, 0)
        let firstID = await gate.id
        _ = try await runtime.sendRecovering(handle, response: FixtureOutput.self, store: receipts) { attempt in
            XCTAssertEqual(attempt.id, firstID); XCTAssertEqual(attempt.number, 1); return true
        }
        XCTAssertEqual(FixtureTransport.generationCount, 1)
    }

    func testRateLimitCooldownSurvivesSuspension() async throws {
        FixtureTransport.configure(["news": [.http(429, ["Retry-After": "1"]), .complete("later")]])
        let runtime = try fixtureRuntime()
        let handle = try await prepare(runtime)
        let receipts = store
        let task = Task { try await runtime.sendRecovering(handle, response: FixtureOutput.self, store: receipts) { _ in true } }
        try await waitUntil { try await runtime.structuredRecoveryStatus(handle, store: receipts).availability == .waiting }
        task.cancel()
        do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        let saved = try await runtime.structuredRecoveryStatus(handle, store: receipts)
        let eligibleAt = try XCTUnwrap(saved.nextAttemptAt)
        let reopened = try fixtureRuntime()
        _ = try await reopened.sendRecovering(handle, response: FixtureOutput.self, store: receipts) { attempt in
            XCTAssertGreaterThanOrEqual(Date(), eligibleAt)
            XCTAssertEqual(attempt.number, 2); return true
        }
        XCTAssertEqual(FixtureTransport.generationCount, 2)
    }
}

private actor AuthorizationGate {
    var entered = false
    var id: String?
    var continuation: CheckedContinuation<Void, Never>?
    func hold(_ id: String) async {
        self.id = id; entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}
