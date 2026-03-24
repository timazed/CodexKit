import CryptoKit
import Foundation
import Security

extension URL {
    var isLoopbackOAuthRedirect: Bool {
        guard let scheme = scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = host?.lowercased(),
              host == "localhost" || host == "127.0.0.1",
              port != nil else {
            return false
        }

        return true
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

struct OAuthCallback {
    let code: String
    let state: String

    init(url: URL) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw AgentRuntimeError(
                code: "oauth_callback_invalid",
                message: "The ChatGPT sign-in callback URL could not be parsed."
            )
        }

        let queryItems = components.queryItems ?? []

        if let errorDescription = queryItems.first(where: { $0.name == "error_description" || $0.name == "error" })?.value {
            throw AgentRuntimeError(
                code: "oauth_callback_failed",
                message: "ChatGPT sign-in failed: \(errorDescription)"
            )
        }

        guard let code = queryItems.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw AgentRuntimeError(
                code: "oauth_callback_missing_code",
                message: "The ChatGPT sign-in callback did not include an authorization code."
            )
        }
        guard let state = queryItems.first(where: { $0.name == "state" })?.value, !state.isEmpty else {
            throw AgentRuntimeError(
                code: "oauth_callback_missing_state",
                message: "The ChatGPT sign-in callback did not include a state parameter."
            )
        }

        self.code = code
        self.state = state
    }
}

struct OAuthState {
    let value: String

    static func generate() -> OAuthState {
        OAuthState(value: randomData(count: 32).base64URLEncodedString())
    }
}

struct PKCECodes {
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
            throw AgentRuntimeError(
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
            throw AgentRuntimeError(
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
