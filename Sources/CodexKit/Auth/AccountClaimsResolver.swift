import CoreFoundation
import Foundation

/// Decoding metadata is not signature verification. Only use credentials supplied by the
/// authentication transport or the selected credential store. Never log claim contents.
struct JWTClaims {
    private let values: [String: Any]
    private var auth: [String: Any] { values["https://api.openai.com/auth"] as? [String: Any] ?? [:] }
    private var profile: [String: Any] { values["https://api.openai.com/profile"] as? [String: Any] ?? [:] }

    // A present but unsupported/malformed authoritative value must not become a legacy plan.
    private func value(_ key: String, namespace: [String: Any]) -> String? {
        Self.string(namespace.keys.contains(key) ? namespace[key] : values[key])
    }
    static func string(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    private var malformedAuth: Bool {
        values.keys.contains("https://api.openai.com/auth") && !(values["https://api.openai.com/auth"] is [String: Any])
    }
    private var malformedProfile: Bool {
        values.keys.contains("https://api.openai.com/profile") && !(values["https://api.openai.com/profile"] is [String: Any])
    }
    var email: String? { malformedProfile ? nil : value("email", namespace: profile) }
    var name: String? { malformedProfile ? nil : value("name", namespace: profile) }
    var chatGPTAccountID: String? { malformedAuth ? nil : value("chatgpt_account_id", namespace: auth) }
    var userID: String? { Self.string(auth["chatgpt_user_id"]) ?? Self.string(auth["user_id"]) }
    var fedramp: Bool { auth["chatgpt_account_is_fedramp"] as? Bool == true }
    var planType: String? { malformedAuth ? nil : value("chatgpt_plan_type", namespace: auth) }
    var hasPlan: Bool { malformedAuth || auth.keys.contains("chatgpt_plan_type") || values.keys.contains("chatgpt_plan_type") }
    var issuedAt: Date? { date("iat") }
    var expiresAt: Date? { date("exp") }
    private func date(_ key: String) -> Date? {
        guard let number = values[key] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue > 0 else { return nil }
        return Date(timeIntervalSince1970: number.doubleValue)
    }
    static func decode(from jwt: String) throws -> Self {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[0].isEmpty, !parts[1].isEmpty else {
            throw ChatGPTSessionError.malformedCredentials
        }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let values = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ChatGPTSessionError.malformedCredentials
        }
        return Self(values: values)
    }
}

enum AccountClaimsResolver {
    static func account(id: JWTClaims?, access: JWTClaims?) throws -> ChatGPTAccount {
        if let lhs = id?.chatGPTAccountID, let rhs = access?.chatGPTAccountID, lhs != rhs {
            throw ChatGPTSessionError.accountChanged
        }
        if let lhs = id?.userID, let rhs = access?.userID, lhs != rhs {
            throw ChatGPTSessionError.accountChanged
        }
        return .init(id: id?.chatGPTAccountID ?? access?.chatGPTAccountID ?? "unknown-account",
                     email: id?.email ?? access?.email ?? "unknown@chatgpt.local",
                     plan: .resolve(id?.hasPlan == true ? id?.planType : access?.planType),
                     name: id?.name)
    }

    static func session(from response: TokenResponse, fallbackRefreshToken: String? = nil) throws -> ChatGPTSession {
        let id = try? JWTClaims.decode(from: response.idToken)
        let access = try? JWTClaims.decode(from: response.accessToken)
        return ChatGPTSession(accessToken: response.accessToken,
                              refreshToken: response.refreshToken ?? fallbackRefreshToken,
                              idToken: response.idToken, account: try account(id: id, access: access),
                              acquiredAt: access?.issuedAt ?? Date(), expiresAt: access?.expiresAt)
    }

    static func placeholderID(_ value: String) -> Bool { value.isEmpty || value == "unknown-account" }
    static func placeholderEmail(_ value: String) -> Bool { value.isEmpty || value == "unknown@chatgpt.local" }

    /// Only fills gaps; a cold reopen never replaces valid host metadata or credentials.
    static func repair(_ previous: ChatGPTSession) throws -> ChatGPTSession {
        guard !previous.isExternallyManaged else { return previous }
        let resolved = try account(id: previous.idToken.flatMap { try? JWTClaims.decode(from: $0) },
                                   access: try? JWTClaims.decode(from: previous.accessToken))
        try validate(resolved, against: previous.account)
        var result = previous
        if placeholderID(result.account.id) { result.account.id = resolved.id }
        if placeholderEmail(result.account.email) { result.account.email = resolved.email }
        if result.account.plan == .unknown { result.account.plan = resolved.plan }
        if result.account.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            result.account.name = resolved.name ?? result.account.name
        }
        return result
    }

    static func validate(_ candidate: ChatGPTAccount, against previous: ChatGPTAccount) throws {
        if !placeholderID(previous.id), !placeholderID(candidate.id), previous.id != candidate.id {
            throw ChatGPTSessionError.accountChanged
        }
    }

    static func refreshed(_ response: TokenResponse, previous: ChatGPTSession) throws -> ChatGPTSession {
        var result = try session(from: response, fallbackRefreshToken: previous.refreshToken)
        try validate(result.account, against: previous.account)
        // Compare user identities too when the old credentials supply one.
        let oldID = previous.idToken.flatMap { try? JWTClaims.decode(from: $0) }
        let oldAccess = try? JWTClaims.decode(from: previous.accessToken)
        let newID = try? JWTClaims.decode(from: response.idToken)
        let newAccess = try? JWTClaims.decode(from: response.accessToken)
        if let oldUser = oldID?.userID ?? oldAccess?.userID,
           let newUser = newID?.userID ?? newAccess?.userID, oldUser != newUser {
            throw ChatGPTSessionError.accountChanged
        }
        if placeholderID(result.account.id) { result.account.id = previous.account.id }
        if placeholderEmail(result.account.email) { result.account.email = previous.account.email }
        if newID?.hasPlan != true && newAccess?.hasPlan != true {
            result.account.plan = previous.account.plan
        }
        result.account.name = result.account.name ?? previous.account.name
        result.ownership = previous.ownership
        result.credentialGeneration = previous.credentialGeneration
        return result
    }
}
