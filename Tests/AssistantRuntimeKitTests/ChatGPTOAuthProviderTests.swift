import AssistantRuntimeKit
import XCTest

private final class MockWebAuthenticationProvider: ChatGPTWebAuthenticationProviding, @unchecked Sendable {
    private(set) var authorizeURL: URL?

    func authenticate(
        authorizeURL: URL,
        callbackScheme: String
    ) async throws -> URL {
        self.authorizeURL = authorizeURL

        let components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)
        let state = components?.queryItems?.first(where: { $0.name == "state" })?.value ?? ""
        return URL(string: "\(callbackScheme)://oauth/callback?code=test-auth-code&state=\(state)")!
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
        let redirectURI = URL(string: "assistant-runtime://oauth/callback")!
        let provider = ChatGPTOAuthProvider(
            configuration: ChatGPTOAuthConfiguration(redirectURI: redirectURI),
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
                    XCTAssertEqual(form["redirect_uri"], redirectURI.absoluteString)
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
        XCTAssertEqual(mockBrowser.authorizeURL?.host, "auth.openai.com")
        XCTAssertEqual(
            URLComponents(url: try XCTUnwrap(mockBrowser.authorizeURL), resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "scope" })?
                .value,
            "openid profile email offline_access api.connectors.read api.connectors.invoke"
        )
    }

    func testRefreshUsesRefreshTokenGrant() async throws {
        let mockBrowser = MockWebAuthenticationProvider()
        let session = makeTestURLSession()
        let redirectURI = URL(string: "assistant-runtime://oauth/callback")!
        let provider = ChatGPTOAuthProvider(
            configuration: ChatGPTOAuthConfiguration(redirectURI: redirectURI),
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
}
