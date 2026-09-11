@testable import CodexKit
import XCTest

final class SessionRestorationRegressionTests: XCTestCase {
    func testConcreteRestoreLoadsCredentialsFromColdStorage() async throws {
        let store = ExternalFixtureStore()
        let stored = demoSession()
        store.appSession = stored
        let manager = externalManager(store: store)
        let before = await manager.currentSession()
        XCTAssertNil(before)
        let restored = try await manager.restore()
        XCTAssertEqual(restored?.accessToken, stored.accessToken)
        XCTAssertEqual(restored?.binding, stored.binding)
    }

    func testProtocolRestoreLoadsCredentialsInsteadOfReturningEmptyCache() async throws {
        let store = ExternalFixtureStore()
        let stored = demoSession()
        store.appSession = stored
        let provider: any AgentSessionProviding = externalManager(store: store)
        let before = await provider.currentSession()
        XCTAssertNil(before)
        let restored = try await provider.restore()
        XCTAssertEqual(restored?.accessToken, stored.accessToken)
        XCTAssertEqual(restored?.binding, stored.binding)
        let cached = await provider.currentSession()
        XCTAssertEqual(cached?.accessToken, stored.accessToken)
    }

    func testGenericRestoreUsesConcreteImplementation() async throws {
        let store = ExternalFixtureStore()
        let stored = demoSession()
        store.appSession = stored
        let restored = try await restoreThroughGeneric(externalManager(store: store))
        XCTAssertEqual(restored?.accessToken, stored.accessToken)
    }

    func testExternalRestoreRevalidatesBindingWithoutSwitchingToAppCredentials() async throws {
        let store = ExternalFixtureStore()
        let stored = demoSession()
        store.appSession = stored
        let source = ExternalFixtureSource()
        let manager = externalManager(store: store)
        let connected = try await manager.connectExternalSession(source: source)
        await source.set(externalSession(token: "rotated-restore-token"))
        let provider: any AgentSessionProviding = manager
        let restored = try await provider.restore()
        XCTAssertEqual(restored?.accessToken, "rotated-restore-token")
        XCTAssertEqual(restored?.binding, connected.binding)
        XCTAssertEqual(store.appSession, stored)
        XCTAssertEqual(store.counts.writes, 0)
        XCTAssertEqual(store.counts.deletes, 0)
    }

    func testMissingExternalCredentialsNeverFallBackToAppOwnedSession() async throws {
        let store = ExternalFixtureStore()
        let stored = demoSession()
        store.appSession = stored
        let source = ExternalFixtureSource()
        let manager = externalManager(store: store)
        _ = try await manager.connectExternalSession(source: source)
        await source.fail(.missingCredentials)
        let provider: any AgentSessionProviding = manager
        do {
            _ = try await provider.restore()
            XCTFail("An explicit external binding must not fall back to app credentials")
        } catch {
            XCTAssertEqual(error as? ChatGPTSessionError, .missingCredentials)
        }
        XCTAssertEqual(store.appSession, stored)
        XCTAssertEqual(store.counts.writes, 0)
        XCTAssertEqual(store.counts.deletes, 0)
    }

    private func restoreThroughGeneric<Provider: AgentSessionProviding>(
        _ provider: Provider
    ) async throws -> ChatGPTSession? {
        try await provider.restore()
    }
}
