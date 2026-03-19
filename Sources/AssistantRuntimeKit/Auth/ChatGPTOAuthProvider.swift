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
        userAgentProduct: String = "AssistantRuntimeKit"
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

#if canImport(AuthenticationServices)
@available(iOS 13.0, macOS 10.15, *)
public final class SystemChatGPTWebAuthenticationProvider: NSObject, ChatGPTWebAuthenticationProviding, @unchecked Sendable {
    private var activeSession: ASWebAuthenticationSession?
    private var activePresentationContextProvider: PresentationContextProvider?
    private let presentationAnchorProvider: @MainActor @Sendable () -> ASPresentationAnchor?

    public override convenience init() {
        self.init(presentationAnchorProvider: {
            defaultPresentationAnchor()
        })
    }

    public init(
        presentationAnchorProvider: @escaping @MainActor @Sendable () -> ASPresentationAnchor?
    ) {
        self.presentationAnchorProvider = presentationAnchorProvider
        super.init()
    }

    public func authenticate(
        authorizeURL: URL,
        callbackScheme: String
    ) async throws -> URL {
        let anchor = try await MainActor.run { () throws -> ASPresentationAnchor in
            guard let anchor = presentationAnchorProvider() else {
                throw AssistantRuntimeError(
                    code: "oauth_presentation_anchor_unavailable",
                    message: "The ChatGPT sign-in sheet could not be presented because no active window was available."
                )
            }
            return anchor
        }

        return try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor [weak self] in
                let session = ASWebAuthenticationSession(
                    url: authorizeURL,
                    callbackURLScheme: callbackScheme
                ) { callbackURL, error in
                    self?.activeSession = nil
                    self?.activePresentationContextProvider = nil

                    if let callbackURL {
                        continuation.resume(returning: callbackURL)
                        return
                    }

                    continuation.resume(
                        throwing: error ?? AssistantRuntimeError(
                            code: "oauth_authentication_cancelled",
                            message: "The ChatGPT sign-in flow did not complete."
                        )
                    )
                }
                let contextProvider = PresentationContextProvider(anchor: anchor)
                session.presentationContextProvider = contextProvider
                #if os(iOS)
                session.prefersEphemeralWebBrowserSession = false
                #endif
                self?.activeSession = session
                self?.activePresentationContextProvider = contextProvider

                guard session.start() else {
                    self?.activeSession = nil
                    self?.activePresentationContextProvider = nil
                    continuation.resume(
                        throwing: AssistantRuntimeError(
                            code: "oauth_authentication_start_failed",
                            message: "The ChatGPT sign-in flow could not be started."
                        )
                    )
                    return
                }
            }
        }
    }
}

@available(iOS 13.0, macOS 10.15, *)
private final class PresentationContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let anchor: ASPresentationAnchor

    init(anchor: ASPresentationAnchor) {
        self.anchor = anchor
    }

    func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor
    }
}

@MainActor
@available(iOS 13.0, macOS 10.15, *)
private func defaultPresentationAnchor() -> ASPresentationAnchor? {
    #if canImport(UIKit)
    let scenes = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }

    if let keyWindow = scenes
        .flatMap(\.windows)
        .first(where: \.isKeyWindow) {
        return keyWindow
    }

    return scenes
        .flatMap(\.windows)
        .first(where: { !$0.isHidden })
    #elseif canImport(AppKit)
    return NSApp.keyWindow ?? NSApp.mainWindow
    #else
    return nil
    #endif
}
#endif

public final class ChatGPTOAuthProvider: ChatGPTAuthProviding, @unchecked Sendable {
    private let configuration: ChatGPTOAuthConfiguration
    private let urlSession: URLSession
    private let webAuthenticationProvider: any ChatGPTWebAuthenticationProviding

    public init(
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
            throw AssistantRuntimeError(
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
            throw AssistantRuntimeError(
                code: "missing_refresh_token",
                message: "This ChatGPT session cannot be refreshed because no refresh token is available."
            )
        }

        let tokenResponse = try await refreshAccessToken(refreshToken)
        return try makeSession(from: tokenResponse, fallbackRefreshToken: refreshToken)
    }

    public func signOut(session _: ChatGPTSession?) async {}

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
            throw AssistantRuntimeError(
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
            throw AssistantRuntimeError(
                code: "oauth_token_response_invalid",
                message: "The ChatGPT token exchange returned an invalid response."
            )
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            let body = simplifyAuthErrorBody(data)
            throw AssistantRuntimeError(
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

struct AuthorizationCodeExchangeRequest: Encodable {
    let clientID: String
    let grantType: String
    let code: String
    let redirectURI: String
    let codeVerifier: String

    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case grantType = "grant_type"
        case code
        case redirectURI = "redirect_uri"
        case codeVerifier = "code_verifier"
    }
}

struct RefreshTokenRequest: Encodable {
    let clientID: String
    let grantType: String
    let refreshToken: String

    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case grantType = "grant_type"
        case refreshToken = "refresh_token"
    }
}

struct TokenResponse: Decodable {
    let idToken: String
    let accessToken: String
    let refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case idToken = "id_token"
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
    }
}

private struct OAuthCallback {
    let code: String
    let state: String

    init(url: URL) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw AssistantRuntimeError(
                code: "oauth_callback_invalid",
                message: "The ChatGPT sign-in callback URL could not be parsed."
            )
        }

        let queryItems = components.queryItems ?? []

        if let errorDescription = queryItems.first(where: { $0.name == "error_description" || $0.name == "error" })?.value {
            throw AssistantRuntimeError(
                code: "oauth_callback_failed",
                message: "ChatGPT sign-in failed: \(errorDescription)"
            )
        }

        guard let code = queryItems.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw AssistantRuntimeError(
                code: "oauth_callback_missing_code",
                message: "The ChatGPT sign-in callback did not include an authorization code."
            )
        }
        guard let state = queryItems.first(where: { $0.name == "state" })?.value, !state.isEmpty else {
            throw AssistantRuntimeError(
                code: "oauth_callback_missing_state",
                message: "The ChatGPT sign-in callback did not include a state parameter."
            )
        }

        self.code = code
        self.state = state
    }
}

private struct OAuthState {
    let value: String

    static func generate() -> OAuthState {
        OAuthState(value: randomData(count: 32).base64URLEncodedString())
    }
}

private struct PKCECodes {
    let codeVerifier: String
    let codeChallenge: String

    init() {
        let verifierData = randomData(count: 64)
        codeVerifier = verifierData.base64URLEncodedString()
        codeChallenge = Data(SHA256.hash(data: Data(codeVerifier.utf8))).base64URLEncodedString()
    }
}

struct JWTClaims: Decodable {
    let email: String?
    let chatGPTAccountID: String?
    let planType: String?
    let issuedAtSeconds: TimeInterval?
    let expiresAtSeconds: TimeInterval?

    enum CodingKeys: String, CodingKey {
        case email
        case chatGPTAccountID = "chatgpt_account_id"
        case planType = "chatgpt_plan_type"
        case issuedAtSeconds = "iat"
        case expiresAtSeconds = "exp"
    }

    var issuedAt: Date? {
        issuedAtSeconds.map(Date.init(timeIntervalSince1970:))
    }

    var expiresAt: Date? {
        expiresAtSeconds.map(Date.init(timeIntervalSince1970:))
    }

    static func decode(from jwt: String) throws -> JWTClaims {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else {
            throw AssistantRuntimeError(
                code: "jwt_invalid",
                message: "A ChatGPT token could not be decoded."
            )
        }

        let payload = try Data(base64URLString: String(parts[1]))
        return try JSONDecoder().decode(JWTClaims.self, from: payload)
    }
}

func buildCodexLikeUserAgent(
    originator: String,
    product: String
) -> String {
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        ?? Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        ?? "0.1"
    let platform = currentPlatformDescription()
    return "\(originator)/\(version) (\(platform)) \(product)"
}

private func currentPlatformDescription() -> String {
    let osVersion = ProcessInfo.processInfo.operatingSystemVersion
    let version = "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
    #if os(iOS)
    let system = "iOS"
    #elseif os(macOS)
    let system = "macOS"
    #elseif os(tvOS)
    let system = "tvOS"
    #elseif os(watchOS)
    let system = "watchOS"
    #elseif os(visionOS)
    let system = "visionOS"
    #else
    let system = "Apple"
    #endif
    return "\(system) \(version); \(currentArchitecture())"
}

private func currentArchitecture() -> String {
    var systemInfo = utsname()
    uname(&systemInfo)
    let mirror = Mirror(reflecting: systemInfo.machine)
    let identifier = mirror.children.reduce(into: "") { partial, element in
        guard let value = element.value as? Int8, value != 0 else {
            return
        }
        partial.append(Character(UnicodeScalar(UInt8(value))))
    }
    return identifier.isEmpty ? "unknown" : identifier
}

func urlEncodedFormBody(_ items: [(String, String)]) -> Data {
    let body = items
        .map { key, value in
            "\(percentEncodeFormComponent(key))=\(percentEncodeFormComponent(value))"
        }
        .joined(separator: "&")
    return Data(body.utf8)
}

private func percentEncodeFormComponent(_ value: String) -> String {
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
}

func simplifyAuthErrorBody(_ data: Data) -> String {
    let body = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let body, !body.isEmpty else {
        return "Unknown error"
    }

    if body.localizedCaseInsensitiveContains("<!doctype html") ||
        body.localizedCaseInsensitiveContains("<html") {
        if body.localizedCaseInsensitiveContains("just a moment") {
            return "The authentication service returned a browser challenge page (for example a Cloudflare anti-bot check) instead of JSON."
        }
        return "The authentication service returned an HTML page instead of JSON."
    }

    return body
}

private extension Data {
    init(base64URLString: String) throws {
        var normalized = base64URLString
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder != 0 {
            normalized += String(repeating: "=", count: 4 - remainder)
        }

        guard let data = Data(base64Encoded: normalized) else {
            throw AssistantRuntimeError(
                code: "jwt_payload_invalid",
                message: "A ChatGPT token payload could not be decoded."
            )
        }
        self = data
    }

    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private func randomData(count: Int) -> Data {
    var bytes = [UInt8](repeating: 0, count: count)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    if status == errSecSuccess {
        return Data(bytes)
    }
    return Data((0 ..< count).map { _ in UInt8.random(in: .min ... .max) })
}
