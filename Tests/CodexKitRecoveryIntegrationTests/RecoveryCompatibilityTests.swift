import CodexKit
import Foundation
import RecoveryIntegrationSupport
import XCTest

@MainActor
final class RecoveryCompatibilityTests: XCTestCase {
    var directory: URL!
    var store: AgentStructuredRecoveryStore { .init(directory: directory) }
    override func setUp() async throws { directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: directory) }
    func prepare(_ runtime: AgentRuntime, expiry: Date? = nil) async throws -> AgentStructuredRecoveryHandle {
        let thread = try await runtime.createThread()
        return try await runtime.prepareStructuredRecovery(Request(text: "news", executionMode: .ephemeral), in: thread.id,
            response: FixtureOutput.self, store: store, expiresAt: expiry,
            retryPolicy: .init(backoff: .init(initialBackoff: 0, maxBackoff: 0)), contractVersion: "v1")
    }

    func testOldContractAndExpiredGenerationPermissionDoNotHideSavedReceipt() async throws {
        FixtureTransport.configure(["news": [.complete("old contract")]])
        let runtime = try fixtureRuntime()
        let handle = try await prepare(runtime, expiry: Date().addingTimeInterval(1))
        _ = try await runtime.sendRecovering(handle, response: FixtureOutput.self, store: store) { _ in true }
        try await Task.sleep(for: .seconds(1.05))
        let reopened = try fixtureRuntime(selector: RejectingSelector())
        do {
            _ = try await reopened.sendRecovering(handle, response: ChangedFixtureOutput.self, store: store) { _ in true }
            XCTFail("A changed contract must be migrated deliberately")
        } catch { XCTAssertEqual(error as? AgentRecoveryError, .formatMismatch) }
        let receipt = try await reopened.structuredRecoveryReceipt(handle, store: store)
        XCTAssertEqual(receipt.contractVersion, "v1")
        let old = try receipt.decode(FixtureOutput.self)
        XCTAssertEqual(old.value, "old contract")
        let status = try await reopened.structuredRecoveryStatus(handle, store: store)
        XCTAssertEqual(status.availability, .completionSaved)
        XCTAssertEqual(FixtureTransport.generationCount, 1)
        try await reopened.acknowledgeStructuredRecovery(handle, store: store)
        try await reopened.acknowledgeStructuredRecovery(handle, store: store)
        let acknowledged = try await reopened.structuredRecoveryStatus(handle, store: store)
        XCTAssertEqual(acknowledged.state, .acknowledged)
    }

    func testAuthenticationReissueConsumesSameBudgetAndFreshCredentials() async throws {
        FixtureTransport.configure(["news": [.http(401, [:]), .complete("renewed")]])
        let session = FixtureSession()
        let runtime = try fixtureRuntime(session: session)
        let handle = try await prepare(runtime)
        _ = try await runtime.sendRecovering(handle, response: FixtureOutput.self, store: store) { attempt in
            if attempt.number == 2 { XCTAssertEqual(attempt.reason, .authenticationReissue) }
            return true
        }
        let status = try await runtime.structuredRecoveryStatus(handle, store: store)
        XCTAssertEqual(status.attemptsUsed, 2)
        XCTAssertEqual(FixtureTransport.generationCount, 2)
        XCTAssertEqual(FixtureTransport.captures.last?.authorization, "Bearer renewed")
        let renewals = await session.renewals
        XCTAssertEqual(renewals, 1)
    }

    func testAccountSwitchDuringAuthorizationCannotTransmitOrReadOtherAccount() async throws {
        FixtureTransport.configure(["news": [.complete("private")]])
        let session = FixtureSession()
        let runtime = try fixtureRuntime(session: session)
        let handle = try await prepare(runtime)
        do {
            _ = try await runtime.sendRecovering(handle, response: FixtureOutput.self, store: store) { _ in
                await session.switchAccount(); return true
            }
            XCTFail()
        } catch { XCTAssertEqual(error as? ChatGPTSessionError, .accountChanged) }
        let status = try await runtime.structuredRecoveryStatus(handle, store: store)
        XCTAssertEqual(status.blocker, .accountMismatch)
        XCTAssertNil(status.lastFailure)
        XCTAssertEqual(FixtureTransport.generationCount, 0)
        let originalAccount = try fixtureRuntime()
        _ = try await originalAccount.sendRecovering(handle, response: FixtureOutput.self, store: store) { _ in true }
        do { _ = try await runtime.structuredRecoveryReceipt(handle, store: store); XCTFail() }
        catch { XCTAssertEqual(error as? ChatGPTSessionError, .accountChanged) }
    }

    func testInvalidOutputRemainsFailedUntilManualRetry() async throws {
        FixtureTransport.configure(["news": [.invalid, .complete("valid")]])
        let runtime = try fixtureRuntime()
        let handle = try await prepare(runtime)
        do { _ = try await runtime.sendRecovering(handle, response: FixtureOutput.self, store: store) { _ in true }; XCTFail() }
        catch { XCTAssertNotNil(error as? AgentRuntimeError) }
        for _ in 0..<2 {
            do { _ = try await runtime.sendRecovering(handle, response: FixtureOutput.self, store: store) { _ in true }; XCTFail() }
            catch { XCTAssertEqual(error as? AgentRecoveryError, .permanentlyFailed) }
        }
        XCTAssertEqual(FixtureTransport.generationCount, 1)
        let retry = try await runtime.retryStructuredRecovery(handle, retryActionID: UUID(), store: store)
        _ = try await runtime.sendRecovering(retry, response: FixtureOutput.self, store: store) { _ in true }
        XCTAssertEqual(FixtureTransport.generationCount, 2)
    }

    func testCompletedButNotPersistedIsNeverReturnedAndDoesNotAutomaticallyRegenerate() async throws {
        FixtureTransport.configure(["news": [.complete(String(repeating: "x", count: 20_000))]])
        let runtime = try fixtureRuntime()
        let handle = try await prepare(runtime)
        let path = directory.appendingPathComponent(handle.id.uuidString + ".json")
        let size = try Data(contentsOf: path).count
        let constrained = AgentStructuredRecoveryStore(directory: directory, maximumBytes: size + 4096)
        do {
            _ = try await runtime.sendRecovering(handle, response: FixtureOutput.self, store: constrained) { _ in true }
            XCTFail("An unpersisted completion must not escape")
        } catch { XCTAssertEqual(error as? AgentRecoveryError, .storageLimitExceeded) }
        XCTAssertEqual(FixtureTransport.generationCount, 1)
        let status = try await runtime.structuredRecoveryStatus(handle, store: store)
        XCTAssertEqual(status.attemptsUsed, 1)
        XCTAssertFalse(status.hasSavedCompletion)
        do { _ = try await runtime.structuredRecoveryReceipt(handle, store: store); XCTFail() }
        catch { XCTAssertEqual(error as? AgentRecoveryError, .completionUnavailable) }
    }

    func testAlpha30RecordPreservesBudgetAndUnknownVersionIsNotDeleted() async throws {
        FixtureTransport.configure(["news": [.complete("legacy")]])
        let runtime = try fixtureRuntime()
        let handle = try await prepare(runtime)
        let path = directory.appendingPathComponent(handle.id.uuidString + ".json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        json["version"] = 1; json["attemptsUsed"] = 2; json["state"] = "running"
        for key in ["preparedRequest", "retryPolicy", "attempts"] { json.removeValue(forKey: key) }
        try JSONSerialization.data(withJSONObject: json).write(to: path, options: .atomic)
        let reopened = try fixtureRuntime(selector: RejectingSelector())
        _ = try await reopened.sendRecovering(handle, response: FixtureOutput.self, store: store) { attempt in
            XCTAssertEqual(attempt.number, 3); return true
        }
        let status = try await reopened.structuredRecoveryStatus(handle, store: store)
        XCTAssertEqual(status.attemptsUsed, 3)
        XCTAssertTrue(status.hasSavedCompletion)
        json["version"] = 999
        let unknown = try JSONSerialization.data(withJSONObject: json)
        try unknown.write(to: path, options: .atomic)
        do { _ = try await reopened.structuredRecoveryStatus(handle, store: store); XCTFail() }
        catch { XCTAssertEqual(error as? AgentRecoveryError, .unsupportedRecordVersion) }
        XCTAssertEqual(try Data(contentsOf: path), unknown)
        XCTAssertEqual(FixtureTransport.generationCount, 1)
    }

    func testRetentionRemovesAcknowledgedPayloadAndSupportsSignOutCleanup() async throws {
        FixtureTransport.configure(["news": [.complete("sensitive payload")]])
        let session = FixtureSession()
        let runtime = try fixtureRuntime(session: session)
        let handle = try await prepare(runtime)
        _ = try await runtime.sendRecovering(handle, response: FixtureOutput.self, store: store) { _ in true }
        let currentSession = await session.currentSession()
        let binding = try XCTUnwrap(currentSession).binding
        try await runtime.acknowledgeStructuredRecovery(handle, store: store)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(handle.id.uuidString + ".json").path))
        await session.signOut()
        let signedOut = try await runtime.structuredRecoveryStatus(handle, store: store)
        XCTAssertEqual(signedOut.availability, .authenticationRequired)
        let result = try store.purgeAccount(binding)
        XCTAssertEqual(result.removed, [handle.id])
        XCTAssertTrue(result.skipped.isEmpty)
    }
}
