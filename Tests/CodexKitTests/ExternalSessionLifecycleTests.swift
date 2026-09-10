@testable import CodexKit
import XCTest

final class ExternalSessionLifecycleTests: XCTestCase {
    func testAppOwnedPersistenceAndExternalDisconnectAreSeparate() async throws {
        let store = ExternalFixtureStore()
        let manager = externalManager(store: store)
        let owned = demoSession()
        _ = try await manager.useSession(owned)
        XCTAssertEqual(store.appSession, owned)
        let source = ExternalFixtureSource()
        _ = try await manager.connectExternalSession(source: source)
        XCTAssertEqual(store.counts.writes, 1)
        try await manager.signOut()
        XCTAssertEqual(store.counts.deletes, 0)
        XCTAssertEqual(store.appSession, owned)
        let ownerSession = try await source.resolve()
        XCTAssertEqual(ownerSession.accessToken, "borrowed-access")
        let state = await manager.authenticationState()
        XCTAssertEqual(state.status, .disconnected)
    }

    func testDisconnectAfterExternalLogoutPreservesApplicationStore() async throws {
        let store = ExternalFixtureStore()
        store.appSession = demoSession()
        let source = ExternalFixtureSource()
        let manager = externalManager(store: store)
        _ = try await manager.connectExternalSession(source: source)
        await source.fail(.missingCredentials)
        do { _ = try await manager.requireSession(); XCTFail("Expected logout") }
        catch { XCTAssertEqual(error as? ChatGPTSessionError, .missingCredentials) }
        try await manager.signOut()
        XCTAssertEqual(store.counts.deletes, 0)
        XCTAssertNotNil(store.appSession)
    }

    func testLegacyExternalMigrationDoesNotReclassifyCredentials() async throws {
        let store = ExternalFixtureStore()
        var legacy = demoSession()
        legacy.isExternallyManaged = true
        store.appSession = legacy
        let manager = externalManager(store: store)
        let restored = try await manager.restore()
        XCTAssertNil(restored)
        XCTAssertNil(store.appSession)
        let state = await manager.authenticationState()
        XCTAssertEqual(state.failure, .reconnectRequired)
        _ = try await manager.useSession(legacy)
        XCTAssertEqual(store.counts.writes, 0)
        do { _ = try await manager.refresh(reason: .unauthorized); XCTFail("Must not refresh borrowed credentials") }
        catch { XCTAssertEqual(error as? ChatGPTSessionError, .reconnectRequired) }
        let current = await manager.currentSession()
        XCTAssertNil(current?.refreshToken)
    }

    func testBindingRestorationAndRotationDoNotPersistCredentials() async throws {
        let store = ExternalFixtureStore()
        let source = ExternalFixtureSource()
        let manager = externalManager(store: store)
        let first = try await manager.connectExternalSession(source: source)
        let encodedBinding = try JSONEncoder().encode(first.binding)
        XCTAssertFalse(String(decoding: encodedBinding, as: UTF8.self).contains(first.accessToken))
        let restoredManager = externalManager(store: store)
        _ = try await restoredManager.connectExternalSession(source: source,
            expectedBinding: JSONDecoder().decode(ChatGPTSessionBinding.self, from: encodedBinding))
        await source.set(externalSession(token: "rotated"))
        let lease = try await restoredManager.requireSession()
        XCTAssertEqual(lease.accessToken, "rotated")
        XCTAssertEqual(store.counts.writes, 0)
        XCTAssertEqual(store.counts.deletes, 0)
    }

    func testExpiredLeaseRequestsOwnerThenReresolves() async throws {
        let clock = ExternalFixtureClock()
        let source = ExternalFixtureSource(externalSession(expiry: clock.now().addingTimeInterval(1000)))
        let owner = ExternalFixtureOwner { await source.set(externalSession(token: "renewed", expiry: clock.now().addingTimeInterval(3600))) }
        let manager = externalManager(clock: clock)
        _ = try await manager.connectExternalSession(source: source, owner: owner)
        clock.advance(1200)
        let renewed = try await manager.requireSession()
        XCTAssertEqual(renewed.accessToken, "renewed")
        let requests = await owner.requests
        XCTAssertEqual(requests, 1)
    }

    func testUnauthorizedRereadsBeforeRequestingOwner() async throws {
        let source = ExternalFixtureSource()
        let owner = ExternalFixtureOwner { XCTFail("Already rotated by owner") }
        let manager = externalManager()
        _ = try await manager.connectExternalSession(source: source, owner: owner)
        await source.set(externalSession(token: "rotated"))
        let renewed = try await manager.recoverUnauthorizedSession(previousAccessToken: "borrowed-access")
        XCTAssertEqual(renewed.accessToken, "rotated")
        let requests = await owner.requests
        XCTAssertEqual(requests, 0)
    }

    func testUnavailableRenewalTransientAndRevokedOutcomesAreDistinct() async throws {
        for failure in [ChatGPTSessionError.reconnectRequired, .transientFailure, .revokedCredentials] {
            let source = ExternalFixtureSource()
            let owner = failure == .reconnectRequired ? nil : ExternalFixtureOwner { throw failure }
            let manager = externalManager()
            _ = try await manager.connectExternalSession(source: source, owner: owner)
            do { _ = try await manager.recoverUnauthorizedSession(previousAccessToken: "borrowed-access"); XCTFail("Expected failure") }
            catch { XCTAssertEqual(error as? ChatGPTSessionError, failure) }
            let state = await manager.authenticationState()
            XCTAssertEqual(state.failure, failure)
            XCTAssertEqual(state.status, failure == .transientFailure ? .unavailable : .reconnectRequired)
        }
    }

    func testConcurrentRenewalsCoalesceAndCancelledWaiterDoesNotCancelOwner() async throws {
        let source = ExternalFixtureSource()
        let gate = ExternalFixtureGate()
        let owner = ExternalFixtureOwner {
            await gate.wait()
            await source.set(externalSession(token: "shared-renewal"))
        }
        let manager = externalManager()
        _ = try await manager.connectExternalSession(source: source, owner: owner)
        let first = Task { try await manager.refresh(reason: .unauthorized) }
        await waitForGate(gate)
        let second = Task { try await manager.refresh(reason: .unauthorized) }
        first.cancel()
        do { _ = try await first.value; XCTFail("Expected cancellation") } catch is CancellationError { }
        await gate.open()
        let result = try await second.value
        XCTAssertEqual(result.accessToken, "shared-renewal")
        let requests = await owner.requests
        XCTAssertEqual(requests, 1)
    }

    func testDisconnectAndReplacementRejectLateOwnerResults() async throws {
        for replace in [false, true] {
            let source = ExternalFixtureSource()
            let gate = ExternalFixtureGate()
            let owner = ExternalFixtureOwner { await gate.wait(); await source.set(externalSession(token: "late")) }
            let store = ExternalFixtureStore()
            let manager = externalManager(store: store)
            _ = try await manager.connectExternalSession(source: source, owner: owner)
            let renewal = Task { try await manager.refresh(reason: .unauthorized) }
            await waitForGate(gate)
            if replace { _ = try await manager.useSession(demoSession()) } else { try await manager.signOut() }
            await gate.open()
            do { _ = try await renewal.value; XCTFail("Late renewal must not win") } catch is CancellationError { }
            let current = await manager.currentSession()
            if replace { XCTAssertEqual(current?.accessToken, demoSession().accessToken) } else { XCTAssertNil(current) }
            XCTAssertEqual(store.counts.writes, replace ? 1 : 0)
        }
    }

    func testOwnerTimeoutDoesNotWaitForAnUncooperativeOwner() async throws {
        let gate = ExternalFixtureGate()
        let owner = ExternalFixtureOwner { await gate.wait() }
        let manager = externalManager(timeout: .milliseconds(20))
        _ = try await manager.connectExternalSession(source: ExternalFixtureSource(), owner: owner)
        do { _ = try await manager.refresh(reason: .unauthorized); XCTFail("Expected timeout") }
        catch { XCTAssertEqual(error as? ChatGPTSessionError, .transientFailure) }
        await gate.open()
    }

    func testSourceLogoutWorkspaceUserAndSourceChangesInvalidateSession() async throws {
        for kind in 0..<4 {
            let source = ExternalFixtureSource()
            let manager = externalManager()
            _ = try await manager.connectExternalSession(source: source)
            if kind == 0 { await source.fail(.missingCredentials) }
            if kind == 1 { await source.set(externalSession(account: "another")) }
            if kind == 2 { await source.set(externalSession(user: "another")) }
            if kind == 3 { await source.set(externalSession(source: "another")) }
            do { _ = try await manager.requireSession(); XCTFail("Expected invalid binding") }
            catch { XCTAssertEqual(error as? ChatGPTSessionError, kind == 0 ? .missingCredentials : (kind == 3 ? .configurationChanged : .accountChanged)) }
            let current = await manager.currentSession()
            XCTAssertNil(current)
        }
    }

    func testRawSourceErrorsCannotLeakIntoDiagnostics() async throws {
        let manager = externalManager()
        do { _ = try await manager.connectExternalSession(source: LeakySource()); XCTFail("Expected sanitized failure") }
        catch {
            XCTAssertEqual(error as? ChatGPTSessionError, .transientFailure)
            XCTAssertFalse(error.localizedDescription.contains("SECRET"))
        }
    }

    private func waitForGate(_ gate: ExternalFixtureGate) async {
        for _ in 0..<1000 {
            if await gate.entered { return }
            await Task.yield()
        }
        XCTFail("Owner did not start")
    }
}

private struct LeakySource: ChatGPTExternalSessionSource {
    func resolve() async throws -> ChatGPTSession {
        throw NSError(domain: "SECRET TOKEN", code: 1, userInfo: [NSLocalizedDescriptionKey: "SECRET TOKEN private account"])
    }
}
