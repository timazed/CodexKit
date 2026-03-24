import CryptoKit
import Foundation
import Security
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

let codexBrowserOAuthRedirectURI = URL(string: "http://localhost:1455/auth/callback")!

public struct ChatGPTOAuthConfiguration: Sendable {
    public let issuerURL: URL
    public let clientID: String
    public let redirectURI: URL
    public let scopes: [String]
    public let originator: String
    public let forcedWorkspaceID: String?
    public let userAgentProduct: String

    public init(
        issuerURL: URL = URL(string: "https://auth.openai.com")!,
        clientID: String = "app_EMoamEEZ73f0CkXaXp7hrann",
        scopes: [String] = [
            "openid",
            "profile",
            "email",
            "offline_access",
            "api.connectors.read",
            "api.connectors.invoke",
        ],
        originator: String = "codex_cli_rs",
        forcedWorkspaceID: String? = nil,
        userAgentProduct: String = "CodexKit"
    ) {
        self.issuerURL = issuerURL
        self.clientID = clientID
        self.redirectURI = codexBrowserOAuthRedirectURI
        self.scopes = scopes
        self.originator = originator
        self.forcedWorkspaceID = forcedWorkspaceID
        self.userAgentProduct = userAgentProduct
    }

    init(
        issuerURL: URL = URL(string: "https://auth.openai.com")!,
        clientID: String = "app_EMoamEEZ73f0CkXaXp7hrann",
        redirectURI: URL,
        scopes: [String] = [
            "openid",
            "profile",
            "email",
            "offline_access",
            "api.connectors.read",
            "api.connectors.invoke",
        ],
        originator: String = "codex_cli_rs",
        forcedWorkspaceID: String? = nil,
        userAgentProduct: String = "CodexKit"
    ) {
        self.issuerURL = issuerURL
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.scopes = scopes
        self.originator = originator
        self.forcedWorkspaceID = forcedWorkspaceID
        self.userAgentProduct = userAgentProduct
    }

    public var callbackScheme: String {
        redirectURI.scheme ?? "assistant-runtime"
    }
}

public protocol ChatGPTWebAuthenticationProviding: Sendable {
    func authenticate(
        authorizeURL: URL,
        callbackScheme: String
    ) async throws -> URL
}

public final class ChatGPTOAuthProvider: ChatGPTAuthProviding, @unchecked Sendable {
    private let configuration: ChatGPTOAuthConfiguration
    private let urlSession: URLSession
    private let webAuthenticationProvider: any ChatGPTWebAuthenticationProviding

    public convenience init(
        configuration: ChatGPTOAuthConfiguration,
        urlSession: URLSession = .shared
    ) {
        self.init(
            configuration: configuration,
            urlSession: urlSession,
            webAuthenticationProvider: Self.makeDefaultWebAuthenticationProvider(for: configuration)
        )
    }

    init(
        configuration: ChatGPTOAuthConfiguration,
        urlSession: URLSession = .shared,
        webAuthenticationProvider: any ChatGPTWebAuthenticationProviding
    ) {
        self.configuration = configuration
        self.urlSession = urlSession
        self.webAuthenticationProvider = webAuthenticationProvider
    }

    public func signInInteractively() async throws -> ChatGPTSession {
        let pkce = PKCECodes()
        let state = OAuthState.generate()
        let authorizeURL = try buildAuthorizeURL(pkce: pkce, state: state)
        let callbackURL = try await webAuthenticationProvider.authenticate(
            authorizeURL: authorizeURL,
            callbackScheme: configuration.callbackScheme
        )
        let callback = try OAuthCallback(url: callbackURL)

        guard callback.state == state.value else {
            throw AgentRuntimeError(
                code: "oauth_state_mismatch",
                message: "The ChatGPT sign-in response could not be validated."
            )
        }

        let tokenResponse = try await exchangeAuthorizationCode(
            callback.code,
            codeVerifier: pkce.codeVerifier
        )
        return try makeSession(from: tokenResponse)
    }

    public func refresh(
        session: ChatGPTSession,
        reason _: ChatGPTAuthRefreshReason
    ) async throws -> ChatGPTSession {
        guard let refreshToken = session.refreshToken, !refreshToken.isEmpty else {
            throw AgentRuntimeError(
                code: "missing_refresh_token",
                message: "This ChatGPT session cannot be refreshed because no refresh token is available."
            )
        }

        let tokenResponse = try await refreshAccessToken(refreshToken)
        return try makeSession(from: tokenResponse, fallbackRefreshToken: refreshToken)
    }

    public func signOut(session _: ChatGPTSession?) async {}

    private static func makeDefaultWebAuthenticationProvider(
        for configuration: ChatGPTOAuthConfiguration
    ) -> any ChatGPTWebAuthenticationProviding {
        if configuration.redirectURI.isLoopbackOAuthRedirect {
            #if canImport(AuthenticationServices) && canImport(Network)
            return LoopbackChatGPTWebAuthenticationProvider()
            #else
            return UnsupportedChatGPTWebAuthenticationProvider()
            #endif
        }

        #if canImport(AuthenticationServices)
        return SystemChatGPTWebAuthenticationProvider()
        #else
        return UnsupportedChatGPTWebAuthenticationProvider()
        #endif
    }

    private func buildAuthorizeURL(
        pkce: PKCECodes,
        state: OAuthState
    ) throws -> URL {
        var components = URLComponents(
            url: configuration.issuerURL.appendingPathComponent("oauth/authorize"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI.absoluteString),
            URLQueryItem(name: "scope", value: configuration.scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: pkce.codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "state", value: state.value),
            URLQueryItem(name: "originator", value: configuration.originator),
        ]

        if let forcedWorkspaceID = configuration.forcedWorkspaceID {
            components?.queryItems?.append(
                URLQueryItem(name: "allowed_workspace_id", value: forcedWorkspaceID)
            )
        }

        guard let url = components?.url else {
            throw AgentRuntimeError(
                code: "oauth_authorize_url_invalid",
                message: "The ChatGPT authorize URL could not be created."
            )
        }
        return url
    }

    private func exchangeAuthorizationCode(
        _ code: String,
        codeVerifier: String
    ) async throws -> TokenResponse {
        var request = URLRequest(url: configuration.issuerURL.appendingPathComponent("oauth/token"))
        request.httpMethod = "POST"
        applyDefaultAuthHeaders(to: &request)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = urlEncodedFormBody(
            [
                ("grant_type", "authorization_code"),
                ("code", code),
                ("redirect_uri", configuration.redirectURI.absoluteString),
                ("client_id", configuration.clientID),
                ("code_verifier", codeVerifier),
            ]
        )
        return try await sendTokenRequest(request)
    }

    private func refreshAccessToken(_ refreshToken: String) async throws -> TokenResponse {
        var request = URLRequest(url: configuration.issuerURL.appendingPathComponent("oauth/token"))
        request.httpMethod = "POST"
        applyDefaultAuthHeaders(to: &request)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = urlEncodedFormBody(
            [
                ("grant_type", "refresh_token"),
                ("client_id", configuration.clientID),
                ("refresh_token", refreshToken),
            ]
        )
        return try await sendTokenRequest(request)
    }

    private func sendTokenRequest(_ request: URLRequest) async throws -> TokenResponse {
        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AgentRuntimeError(
                code: "oauth_token_response_invalid",
                message: "The ChatGPT token exchange returned an invalid response."
            )
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            let body = simplifyAuthErrorBody(data)
            throw AgentRuntimeError(
                code: "oauth_token_exchange_failed",
                message: "ChatGPT token exchange failed with status \(httpResponse.statusCode): \(body)"
            )
        }

        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private func makeSession(
        from response: TokenResponse,
        fallbackRefreshToken: String? = nil
    ) throws -> ChatGPTSession {
        let idClaims = try JWTClaims.decode(from: response.idToken)
        let accessClaims = try JWTClaims.decode(from: response.accessToken)

        let accountID = idClaims.chatGPTAccountID
            ?? accessClaims.chatGPTAccountID
            ?? "unknown-account"
        let email = idClaims.email ?? accessClaims.email ?? "unknown@chatgpt.local"
        let plan = ChatGPTPlanType(
            rawValue: idClaims.planType ?? accessClaims.planType ?? "unknown"
        ) ?? .unknown

        return ChatGPTSession(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken ?? fallbackRefreshToken,
            idToken: response.idToken,
            account: ChatGPTAccount(id: accountID, email: email, plan: plan),
            acquiredAt: accessClaims.issuedAt ?? Date(),
            expiresAt: accessClaims.expiresAt,
            isExternallyManaged: false
        )
    }

    private func applyDefaultAuthHeaders(to request: inout URLRequest) {
        request.setValue(configuration.originator, forHTTPHeaderField: "originator")
        request.setValue(codexLikeUserAgent(), forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
    }

    private func codexLikeUserAgent() -> String {
        buildCodexLikeUserAgent(
            originator: configuration.originator,
            product: configuration.userAgentProduct
        )
    }
}
