@testable import CodexKit
import XCTest

private actor MockWebAuthenticationProvider: ChatGPTWebAuthenticationProviding {
    private(set) var authorizeURL: URL?

    func authenticate(
        authorizeURL: URL,
        callbackScheme _: String
    ) async throws -> URL {
        self.authorizeURL = authorizeURL

        let components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)
        let state = components?.queryItems?.first(where: { $0.name == "state" })?.value ?? ""
        let redirectURI = components?
            .queryItems?
            .first(where: { $0.name == "redirect_uri" })?
            .value ?? codexBrowserOAuthRedirectURI.absoluteString
        var callbackComponents = URLComponents(string: redirectURI)!
        callbackComponents.queryItems = [
            URLQueryItem(name: "code", value: "test-auth-code"),
            URLQueryItem(name: "state", value: state),
        ]
        return callbackComponents.url!
    }
}

final class ChatGPTOAuthProviderTests: XCTestCase {
    override func tearDown() {
        let expectation = XCTestExpectation(description: "reset protocol stubs")
        Task {
            await TestURLProtocol.reset()
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
        super.tearDown()
    }

    func testInteractiveSignInExchangesCodeForTokens() async throws {
        let mockBrowser = MockWebAuthenticationProvider()
        let session = makeTestURLSession()
        let provider = ChatGPTOAuthProvider(
            configuration: ChatGPTOAuthConfiguration(),
            urlSession: session,
            webAuthenticationProvider: mockBrowser
        )

        let now = Date()
        let idToken = try makeUnsignedJWT(
            claims: [
                "email": "taylor@example.com",
                "chatgpt_account_id": "workspace-123",
                "chatgpt_plan_type": "plus",
                "iat": Int(now.timeIntervalSince1970),
                "exp": Int(now.addingTimeInterval(3600).timeIntervalSince1970),
            ]
        )
        let accessToken = try makeUnsignedJWT(
            claims: [
                "chatgpt_account_id": "workspace-123",
                "chatgpt_plan_type": "plus",
                "iat": Int(now.timeIntervalSince1970),
                "exp": Int(now.addingTimeInterval(1800).timeIntervalSince1970),
            ]
        )

        await TestURLProtocol.enqueue(
            .init(
                body: try JSONEncoder().encode([
                    "id_token": idToken,
                    "access_token": accessToken,
                    "refresh_token": "refresh-123",
                ]),
                inspect: { request in
                    XCTAssertEqual(request.url?.absoluteString, "https://auth.openai.com/oauth/token")
                    XCTAssertEqual(request.httpMethod, "POST")
                    XCTAssertEqual(request.value(forHTTPHeaderField: "originator"), "codex_cli_rs")
                    XCTAssertNotNil(request.value(forHTTPHeaderField: "User-Agent"))
                    XCTAssertEqual(
                        request.value(forHTTPHeaderField: "Content-Type"),
                        "application/x-www-form-urlencoded"
                    )
                    let body = try XCTUnwrap(requestBodyData(for: request))
                    let form = parseFormURLEncodedBody(body)
                    XCTAssertEqual(form["grant_type"], "authorization_code")
                    XCTAssertEqual(form["code"], "test-auth-code")
                    XCTAssertEqual(form["redirect_uri"], codexBrowserOAuthRedirectURI.absoluteString)
                    XCTAssertNotNil(form["code_verifier"])
                }
            )
        )

        let signedIn = try await provider.signInInteractively()
        XCTAssertEqual(signedIn.account.id, "workspace-123")
        XCTAssertEqual(signedIn.account.email, "taylor@example.com")
        XCTAssertEqual(signedIn.account.plan, .plus)
        XCTAssertEqual(signedIn.refreshToken, "refresh-123")
        XCTAssertEqual(signedIn.idToken, idToken)
        let capturedAuthorizeURL = await mockBrowser.authorizeURL
        let authorizeURL = try XCTUnwrap(capturedAuthorizeURL)
        XCTAssertEqual(authorizeURL.host, "auth.openai.com")
        XCTAssertEqual(
            URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "redirect_uri" })?
                .value,
            codexBrowserOAuthRedirectURI.absoluteString
        )
        XCTAssertEqual(
            URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "scope" })?
                .value,
            "openid profile email offline_access api.connectors.read api.connectors.invoke"
        )
    }

    func testRefreshUsesRefreshTokenGrant() async throws {
        let mockBrowser = MockWebAuthenticationProvider()
        let session = makeTestURLSession()
        let provider = ChatGPTOAuthProvider(
            configuration: ChatGPTOAuthConfiguration(),
            urlSession: session,
            webAuthenticationProvider: mockBrowser
        )

        let refreshedAccessToken = try makeUnsignedJWT(
            claims: [
                "chatgpt_account_id": "workspace-abc",
                "chatgpt_plan_type": "pro",
                "iat": Int(Date().timeIntervalSince1970),
                "exp": Int(Date().addingTimeInterval(1800).timeIntervalSince1970),
            ]
        )
        let refreshedIDToken = try makeUnsignedJWT(
            claims: [
                "email": "jamie@example.com",
                "chatgpt_account_id": "workspace-abc",
                "chatgpt_plan_type": "pro",
                "iat": Int(Date().timeIntervalSince1970),
                "exp": Int(Date().addingTimeInterval(3600).timeIntervalSince1970),
            ]
        )

        await TestURLProtocol.enqueue(
            .init(
                body: try JSONEncoder().encode([
                    "id_token": refreshedIDToken,
                    "access_token": refreshedAccessToken,
                    "refresh_token": "refresh-456",
                ]),
                inspect: { request in
                    let body = try XCTUnwrap(requestBodyData(for: request))
                    XCTAssertEqual(
                        request.value(forHTTPHeaderField: "Content-Type"),
                        "application/x-www-form-urlencoded"
                    )
                    let form = parseFormURLEncodedBody(body)
                    XCTAssertEqual(form["grant_type"], "refresh_token")
                    XCTAssertEqual(form["refresh_token"], "refresh-123")
                }
            )
        )

        let refreshed = try await provider.refresh(
            session: ChatGPTSession(
                accessToken: "old-access",
                refreshToken: "refresh-123",
                account: ChatGPTAccount(id: "workspace-abc", email: "old@example.com", plan: .free)
            ),
            reason: .unauthorized
        )

        XCTAssertEqual(refreshed.account.id, "workspace-abc")
        XCTAssertEqual(refreshed.account.email, "jamie@example.com")
        XCTAssertEqual(refreshed.account.plan, .pro)
        XCTAssertEqual(refreshed.refreshToken, "refresh-456")
    }

    func testRuntimeUnauthorizedRecoveryRefreshesThroughConcreteProvider() async throws {
        let now = Date()
        let refreshedAccessToken = try makeUnsignedJWT(
            claims: [
                "chatgpt_account_id": "workspace-runtime",
                "chatgpt_plan_type": "plus",
                "iat": Int(now.timeIntervalSince1970),
                "exp": Int(now.addingTimeInterval(1800).timeIntervalSince1970),
            ]
        )
        let refreshedIDToken = try makeUnsignedJWT(
            claims: [
                "email": "runtime@example.com",
                "chatgpt_account_id": "workspace-runtime",
                "chatgpt_plan_type": "plus",
                "iat": Int(now.timeIntervalSince1970),
                "exp": Int(now.addingTimeInterval(3600).timeIntervalSince1970),
            ]
        )

        await TestURLProtocol.enqueue(
            .init(
                body: try JSONEncoder().encode([
                    "id_token": refreshedIDToken,
                    "access_token": refreshedAccessToken,
                    "refresh_token": "refresh-runtime-2",
                ]),
                inspect: { request in
                    let body = try XCTUnwrap(requestBodyData(for: request))
                    let form = parseFormURLEncodedBody(body)
                    XCTAssertEqual(form["grant_type"], "refresh_token")
                    XCTAssertEqual(form["refresh_token"], "refresh-runtime-1")
                }
            )
        )

        let secureStore = KeychainSessionSecureStore(
            service: "CodexKitTests.ChatGPTSession",
            account: UUID().uuidString
        )
        let backend = UnauthorizedThenSuccessBackend()
        let authProvider = try ChatGPTAuthProvider(
            method: .oauth,
            urlSession: makeTestURLSession()
        )
        let runtime = try AgentRuntime(
            configuration: .init(
                authProvider: authProvider,
                secureStore: secureStore,
                backend: backend,
                approvalPresenter: AutoApprovalPresenter(),
                stateStore: InMemoryRuntimeStateStore()
            )
        )
        _ = try await runtime.restore()
        _ = try await runtime.useSession(
            ChatGPTSession(
                accessToken: "runtime-access-token-1",
                refreshToken: "refresh-runtime-1",
                account: ChatGPTAccount(
                    id: "workspace-runtime",
                    email: "runtime@example.com",
                    plan: .plus
                ),
                expiresAt: now.addingTimeInterval(1800)
            )
        )

        let thread = try await runtime.createThread(title: "OAuth Recovery")
        _ = try await runtime.send(Request(text: "Retry after refresh"), in: thread.id)

        let attemptedTokens = await backend.attemptedAccessTokens()
        XCTAssertEqual(attemptedTokens, ["runtime-access-token-1", refreshedAccessToken])
        let currentSession = await runtime.currentSession()
        XCTAssertEqual(currentSession?.accessToken, refreshedAccessToken)
        XCTAssertEqual(currentSession?.refreshToken, "refresh-runtime-2")
    }
}
