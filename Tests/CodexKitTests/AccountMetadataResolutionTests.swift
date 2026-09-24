@testable import CodexKit
import XCTest

@MainActor
private final class MetadataPresenter: ChatGPTDeviceCodePresenting {
    func present(prompt: ChatGPTDeviceCodePrompt) async {}
    func clear() async {}
}

final class AccountMetadataResolutionTests: XCTestCase {
    private let auth = "https://api.openai.com/auth"
    private let profile = "https://api.openai.com/profile"

    override func tearDown() async throws { await TestURLProtocol.reset() }

    private func token(plan: Any = "plus", account: String = "workspace") throws -> String {
        try makeUnsignedJWT(claims: [
            "iss": "https://auth.openai.com", "aud": "app_fixture", "sub": "subject-fixture",
            "iat": 1_780_000_000, "exp": 4_000_000_000,
            auth: ["chatgpt_account_id": account, "chatgpt_user_id": "user-fixture", "chatgpt_plan_type": plan],
            profile: ["email": "fixture@example.test", "name": "Fixture Name"]
        ])
    }

    func testPlanVocabularyAndLegacyCompatibility() throws {
        let cases: [(String, ChatGPTPlanType)] = [
            ("free", .free), ("go", .go), ("plus", .plus), ("pro", .pro), ("prolite", .proLite),
            ("team", .team), ("business", .business), ("self_serve_business_prolite", .selfServeBusinessProLite),
            ("self_serve_business_usage_based", .selfServeBusinessUsageBased), ("enterprise", .enterprise),
            ("hc", .enterprise), ("ent26", .ent26), ("enterprise_cbp_automation", .enterpriseCbpAutomation),
            ("enterprise_cbp_usage_based", .enterpriseCbpUsageBased), ("edu", .edu), ("education", .edu),
            ("edu_plus", .eduPlus), ("edu_pro", .eduPro), ("future_plan", .unknown), ("", .unknown)
        ]
        for (raw, expected) in cases {
            for namespaced in [true, false] {
                let claims: [String: Any] = ["chatgpt_account_id": "workspace", "chatgpt_plan_type": raw]
                let jwt = try makeUnsignedJWT(claims: namespaced ? [auth: claims] : claims)
                let result = try AccountClaimsResolver.session(from: .init(idToken: jwt, accessToken: jwt, refreshToken: nil))
                XCTAssertEqual(result.account.plan, expected)
                XCTAssertEqual(result.account.id, "workspace")
            }
        }
    }

    func testPrecedenceMalformedValuesAndIdentityConflicts() throws {
        let access = try token(plan: "pro")
        for invalid: Any in [NSNull(), 42, ["unexpected": true], "future_plan", ""] {
            let id = try makeUnsignedJWT(claims: [auth: ["chatgpt_plan_type": invalid], "chatgpt_plan_type": "free"])
            let result = try AccountClaimsResolver.session(from: .init(idToken: id, accessToken: access, refreshToken: nil))
            XCTAssertEqual(result.account.plan, .unknown)
            XCTAssertEqual(result.account.email, "fixture@example.test")
        }
        let malformedNamespace = try makeUnsignedJWT(claims: [auth: "invalid", "chatgpt_plan_type": "free"])
        XCTAssertEqual(try AccountClaimsResolver.session(from: .init(idToken: malformedNamespace, accessToken: access, refreshToken: nil)).account.plan, .unknown)
        let preferred = try makeUnsignedJWT(claims: [auth: ["chatgpt_account_id": "workspace", "chatgpt_plan_type": "free"],
                                                    "chatgpt_account_id": "legacy", "chatgpt_plan_type": "pro",
                                                    profile: ["email": "preferred@example.test"], "email": "legacy@example.test"])
        let result = try AccountClaimsResolver.session(from: .init(idToken: preferred, accessToken: access, refreshToken: nil))
        XCTAssertEqual(result.account.id, "workspace")
        XCTAssertEqual(result.account.plan, .free)
        XCTAssertEqual(result.account.email, "preferred@example.test")
        for missing in ["malformed", try makeUnsignedJWT(claims: [:])] {
            let fallback = try AccountClaimsResolver.session(from: .init(idToken: missing, accessToken: access, refreshToken: nil))
            XCTAssertEqual(fallback.account.plan, .pro)
        }
        let unknown = try AccountClaimsResolver.session(from: .init(idToken: "bad", accessToken: "bad", refreshToken: nil))
        XCTAssertEqual(unknown.account.plan, .unknown)
        XCTAssertThrowsError(try AccountClaimsResolver.session(from: .init(idToken: token(account: "other"), accessToken: access, refreshToken: nil))) {
            XCTAssertEqual($0 as? ChatGPTSessionError, .accountChanged)
        }
    }

    func testColdRestorationRepairsPersistsAndLogoutDeletesWithoutTransport() async throws {
        for plan in ["free", "plus", "pro", "go"] {
            let store = KeychainSessionSecureStore(service: "CodexKitTests.Metadata", account: UUID().uuidString)
            defer { try? store.deleteSession() }
            let provider = try ChatGPTAuthProvider(method: .oauth, urlSession: makeTestURLSession())
            let original = ChatGPTSession(accessToken: try token(plan: plan), refreshToken: "fixture-refresh",
                idToken: try token(plan: plan), account: .init(id: "unknown-account", email: "unknown@chatgpt.local", plan: .unknown, name: "Host Name"),
                acquiredAt: Date(timeIntervalSince1970: 123), expiresAt: Date(timeIntervalSince1970: 4_000_000_000))
            try store.saveSession(original)
            let manager = ChatGPTSessionManager(authProvider: provider, secureStore: store)
            let restored = try await manager.restore()
            XCTAssertEqual(restored?.account.plan.rawValue, plan)
            XCTAssertEqual(restored?.account.id, "workspace")
            XCTAssertEqual(restored?.account.email, "fixture@example.test")
            XCTAssertEqual(restored?.account.name, "Host Name")
            XCTAssertEqual(restored?.accessToken, original.accessToken)
            XCTAssertEqual(restored?.idToken, original.idToken)
            XCTAssertEqual(restored?.refreshToken, original.refreshToken)
            XCTAssertEqual(restored?.acquiredAt, original.acquiredAt)
            XCTAssertEqual(restored?.expiresAt, original.expiresAt)
            XCTAssertEqual(try store.loadSession(), restored)
            let reopened = ChatGPTSessionManager(authProvider: provider, secureStore: store)
            let again = try await reopened.restore()
            XCTAssertEqual(again, restored)
            try await reopened.signOut()
            XCTAssertNil(try store.loadSession())
            let afterLogout = try await manager.restore()
            XCTAssertNil(afterLogout)
        }
    }

    func testDeviceSignInAndBothRefreshPathsPersistMetadata() async throws {
        for method in [ChatGPTAuthenticationMethod.deviceCode, .oauth] {
            let store = KeychainSessionSecureStore(service: "CodexKitTests.Metadata", account: UUID().uuidString)
            defer { try? store.deleteSession() }
            let provider = try ChatGPTAuthProvider(method: method, urlSession: makeTestURLSession(), deviceCodePresenter: MetadataPresenter())
            let manager = ChatGPTSessionManager(authProvider: provider, secureStore: store)
            if case .deviceCode = method {
                await TestURLProtocol.enqueue(.init(body: Data(#"{"device_auth_id":"fixture","user_code":"FIXTURE","interval":"1"}"#.utf8)))
                await TestURLProtocol.enqueue(.init(body: Data(#"{"authorization_code":"fixture","code_challenge":"fixture","code_verifier":"fixture"}"#.utf8)))
                await TestURLProtocol.enqueue(.init(body: try JSONEncoder().encode(["id_token": token(plan: "free"), "access_token": token(plan: "free"), "refresh_token": "fixture-refresh"])))
                let signedIn = try await manager.signIn()
                XCTAssertEqual(signedIn.account.plan, .free)
                XCTAssertEqual(try store.loadSession(), signedIn)
            } else {
                try store.saveSession(.init(accessToken: token(plan: "free"), refreshToken: "fixture-refresh",
                    account: .init(id: "workspace", email: "saved@example.test", plan: .free, name: "Saved Name")))
                _ = try await manager.restore()
            }
            let access = try token(plan: "pro")
            await TestURLProtocol.enqueue(.init(body: try JSONEncoder().encode(["id_token": makeUnsignedJWT(claims: [:]), "access_token": access]), inspect: { request in
                XCTAssertEqual(parseFormURLEncodedBody(try XCTUnwrap(requestBodyData(for: request)))["grant_type"], "refresh_token")
            }))
            let refreshed = try await manager.refresh(reason: .unauthorized)
            XCTAssertEqual(refreshed.account.plan, .pro)
            XCTAssertEqual(refreshed.refreshToken, "fixture-refresh")
            XCTAssertEqual(refreshed.accessToken, access)
            let reopened = ChatGPTSessionManager(authProvider: provider, secureStore: store)
            let again = try await reopened.restore()
            XCTAssertEqual(again, refreshed)
            await TestURLProtocol.enqueue(.init(body: try JSONEncoder().encode(["id_token": token(account: "other"), "access_token": token(account: "other")])))
            do { _ = try await reopened.refresh(reason: .unauthorized); XCTFail("Identity switch accepted") }
            catch { XCTAssertEqual(error as? ChatGPTSessionError, .accountChanged) }
            XCTAssertEqual(try store.loadSession(), refreshed)
            try await reopened.signOut()
            XCTAssertNil(try store.loadSession())
        }
    }

    func testMalformedAndExpiredPersistedMetadataNeedsNoRefresh() async throws {
        for jwt in ["not-a-jwt", try makeUnsignedJWT(claims: [auth: ["chatgpt_plan_type": 7], "exp": "invalid"]),
                    try makeUnsignedJWT(claims: [auth: ["chatgpt_plan_type": "future"], "exp": 1])] {
            let store = KeychainSessionSecureStore(service: "CodexKitTests.Metadata", account: UUID().uuidString)
            defer { try? store.deleteSession() }
            let saved = ChatGPTSession(accessToken: jwt, refreshToken: "fixture-refresh",
                account: .init(id: "workspace", email: "host@example.test", plan: .unknown),
                expiresAt: Date(timeIntervalSince1970: 1))
            try store.saveSession(saved)
            let manager = ChatGPTSessionManager(authProvider: try .init(method: .oauth, urlSession: makeTestURLSession()), secureStore: store)
            let restored = try await manager.restore()
            XCTAssertEqual(restored, saved)
            XCTAssertEqual(try store.loadSession(), saved)
        }
    }

    func testUserConflictAndMissingRefreshMetadata() throws {
        let access = try token()
        let conflicting = try makeUnsignedJWT(claims: [auth: ["chatgpt_account_id": "workspace", "chatgpt_user_id": "other-user"]])
        XCTAssertThrowsError(try AccountClaimsResolver.session(from: .init(idToken: conflicting, accessToken: access, refreshToken: nil))) {
            XCTAssertEqual($0 as? ChatGPTSessionError, .accountChanged)
        }
        let previous = ChatGPTSession(accessToken: access, refreshToken: "saved-refresh", idToken: access,
            account: .init(id: "workspace", email: "saved@example.test", plan: .team, name: "Saved Name"))
        let empty = try makeUnsignedJWT(claims: [:])
        let refreshed = try AccountClaimsResolver.refreshed(.init(idToken: empty, accessToken: empty, refreshToken: nil), previous: previous)
        XCTAssertEqual(refreshed.account, previous.account)
        for unsupported: Any in ["future", 42, NSNull()] {
            let jwt = try token(plan: unsupported)
            let unknown = try AccountClaimsResolver.refreshed(.init(idToken: jwt, accessToken: jwt, refreshToken: nil), previous: previous)
            XCTAssertEqual(unknown.account.plan, .unknown)
        }
        XCTAssertEqual(refreshed.binding, previous.binding)
        XCTAssertEqual(refreshed.refreshToken, previous.refreshToken)
        XCTAssertThrowsError(try AccountClaimsResolver.refreshed(.init(idToken: conflicting, accessToken: conflicting, refreshToken: nil), previous: previous)) {
            XCTAssertEqual($0 as? ChatGPTSessionError, .accountChanged)
        }
    }

    func testRestorationPreservesValidMetadataAndRejectsBoundConflict() async throws {
        let store = KeychainSessionSecureStore(service: "CodexKitTests.Metadata", account: UUID().uuidString)
        defer { try? store.deleteSession() }
        let manager = ChatGPTSessionManager(authProvider: try .init(method: .oauth, urlSession: makeTestURLSession()), secureStore: store)
        var saved = ChatGPTSession(accessToken: try token(), account: .init(id: "workspace", email: "host@example.test", plan: .team, name: "Host"))
        try store.saveSession(saved)
        let restored = try await manager.restore()
        XCTAssertEqual(restored, saved)
        saved.account.id = "other"
        try store.saveSession(saved)
        do { _ = try await manager.restore(); XCTFail("Identity switch accepted") }
        catch { XCTAssertEqual(error as? ChatGPTSessionError, .accountChanged) }
        XCTAssertEqual(try store.loadSession(), saved)
    }
}
