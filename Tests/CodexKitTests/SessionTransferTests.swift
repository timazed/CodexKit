@testable import CodexKit
import Foundation
import XCTest

final class SessionTransferTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_900_000_000)
    private var fixture: Data {
        get throws {
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            return try Data(contentsOf: root.appendingPathComponent("Fixtures/session-transfer/v1.json"))
        }
    }
    func testSharedWireFixtureRoundTripAndOwnerExport() throws {
        let transfer = try ChatGPTSessionTransfer.importJSON(fixture, now: now)
        let session = try transfer.validatedSession(now: now)
        XCTAssertEqual(session.accessToken, "synthetic-transfer-secret")
        XCTAssertEqual(session.account.name, "Demo Owner")
        XCTAssertTrue(session.isExternallyManaged)
        XCTAssertNil(session.refreshToken)
        var owner = session
        owner.refreshToken = "synthetic-refresh-secret"
        owner.idToken = "synthetic-id-secret"
        let exported = try ChatGPTSessionTransfer(session: owner, now: now).exportJSON(now: now)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: exported) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: fixture) as? NSDictionary)
        let imported = try ChatGPTSessionTransfer.importJSON(exported, now: now)
        XCTAssertEqual(try imported.validatedSession(now: now).account, session.account)
        XCTAssertFalse(String(data: exported, encoding: .utf8)!.contains("synthetic-refresh-secret"))
        XCTAssertFalse(String(describing: transfer).contains(session.accessToken))
        XCTAssertFalse(String(reflecting: transfer).contains(session.accessToken))
    }
    func testMalformedUnsupportedAndExpiry() throws {
        let original = try JSONSerialization.jsonObject(with: fixture) as! [String: Any]
        let cases: [(String, Any, ChatGPTSessionTransferError)] = [
            ("version", 2, .unsupportedVersion), ("version", true, .malformed),
            ("accessToken", "secret\r\nheader", .malformed), ("accessToken", "", .malformed),
            ("expiresAt", 1_900_000_000, .expired), ("expiresAt", NSNull(), .malformed),
            ("expiresAt", 2_000_000_000.5, .malformed), ("expiresAt", true, .malformed),
            ("provider", "other", .malformed), ("account", ["id": "a", "email": NSNull()], .malformed),
            ("refreshToken", "synthetic-refresh-secret", .malformed)
        ]
        for (key, value, expected) in cases {
            var object = original; object[key] = value
            let data = try JSONSerialization.data(withJSONObject: object)
            XCTAssertThrowsError(try ChatGPTSessionTransfer.importJSON(data, now: now)) {
                XCTAssertEqual($0 as? ChatGPTSessionTransferError, expected)
                XCTAssertFalse(String(reflecting: $0).contains("synthetic"))
            }
        }
        for data in [Data("{secret".utf8), Data("[]".utf8), Data(repeating: 32, count: 65_537)] {
            XCTAssertThrowsError(try ChatGPTSessionTransfer.importJSON(data, now: now)) {
                XCTAssertEqual($0 as? ChatGPTSessionTransferError, .malformed)
            }
        }
        var session = try ChatGPTSessionTransfer.importJSON(fixture, now: now).validatedSession(now: now)
        session.expiresAt = nil
        XCTAssertThrowsError(try ChatGPTSessionTransfer(session: session, now: now)) {
            XCTAssertEqual($0 as? ChatGPTSessionTransferError, .expiryRequired)
        }
    }
    func testMinimalFieldsAndLateExpiry() throws {
        let data = Data(#"{"version":1,"provider":"chatgpt","accessToken":"synthetic","expiresAt":2000000000,"account":{"id":"account"}}"#.utf8)
        let transfer = try ChatGPTSessionTransfer.importJSON(data, now: now)
        XCTAssertEqual(try transfer.validatedSession(now: now).account.plan, .unknown)
        XCTAssertThrowsError(try transfer.exportJSON(now: Date(timeIntervalSince1970: 2_000_000_000))) {
            XCTAssertEqual($0 as? ChatGPTSessionTransferError, .expired)
        }
    }
    func testRuntimeClientImportExportAndInvalidImportPreservesSession() async throws {
        let store = ExternalFixtureStore()
        let manager = externalManager(store: store)
        let runtime = try makeRuntime(manager)
        var owner = demoSession()
        owner.expiresAt = Date().addingTimeInterval(3600)
        owner.refreshToken = "owner-refresh-secret"
        _ = try await runtime.useSession(owner)
        let exported = try await runtime.exportSession()
        let imported = try await runtime.importSession(exported)
        XCTAssertTrue(imported.isTransferred)
        XCTAssertNil(imported.refreshToken)
        XCTAssertEqual(store.appSession?.refreshToken, "owner-refresh-secret")
        do { _ = try await runtime.importSession(Data("invalid".utf8)); XCTFail("Invalid import") }
        catch { XCTAssertEqual(error as? ChatGPTSessionTransferError, .malformed) }
        let current = await runtime.currentSession()
        XCTAssertEqual(current, imported)
        try await runtime.signOut()
        XCTAssertEqual(store.appSession?.refreshToken, "owner-refresh-secret")
    }

    func testImportedGenerationNeverRetries() async throws {
        for status in [401, 503] {
            await TestURLProtocol.reset()
            let manager = externalManager()
            let runtime = try makeRuntime(manager)
            var owner = demoSession()
            owner.expiresAt = Date().addingTimeInterval(3600)
            let data = try ChatGPTSessionTransfer(session: owner).exportJSON()
            _ = try await runtime.importSession(data)
            let thread = try await runtime.createThread()
            await TestURLProtocol.enqueue(.init(statusCode: status, body: Data()))
            await TestURLProtocol.enqueue(.init(statusCode: 200, body: Data(), inspect: { _ in
                XCTFail("Imported credentials must not retry generation or refresh")
            }))
            do { _ = try await runtime.send(Request(text: "Synthetic request"), in: thread.id); XCTFail("Expected failure") }
            catch { /* Runtime may wrap transfer errors in its execution error envelope. */ }
            if status == 401 {
                do { _ = try await manager.requireSession(); XCTFail("Must require replacement") }
                catch { XCTAssertEqual(error as? ChatGPTSessionTransferError, .reauthenticationRequired) }
            }
        }
        await TestURLProtocol.reset()
    }

    private func makeRuntime(_ manager: ChatGPTSessionManager) throws -> AgentRuntime {
        try AgentRuntime(configuration: .init(sessionProvider: manager,
            backend: CodexResponsesBackend(configuration: .init(), urlSession: makeTestURLSession()),
            approvalPresenter: AutoApprovalPresenter(), stateStore: InMemoryRuntimeStateStore()))
    }

    func testImportedProviderDoesNotRecoverOrRefresh() async throws {
        let transfer = try ChatGPTSessionTransfer.importJSON(fixture, now: now)
        let date = now
        let provider = ChatGPTSessionManager(authProvider: try ChatGPTAuthProvider(method: .oauth),
            sessionStore: ExternalFixtureStore(), now: { date })
        _ = try await provider.useSession(transfer.validatedSession(now: date))
        let session = try await provider.requireSession()
        XCTAssertNil(session.refreshToken)
        do {
            _ = try await provider.recoverUnauthorizedSession(previousAccessToken: session.accessToken)
            XCTFail("Must require explicit replacement")
        } catch { XCTAssertEqual(error as? ChatGPTSessionTransferError, .reauthenticationRequired) }
        do {
            _ = try await provider.requireSession()
            XCTFail("Rejected session must remain rejected")
        } catch { XCTAssertEqual(error as? ChatGPTSessionTransferError, .reauthenticationRequired) }
    }
}
