import Foundation

/// Account details and token lifetime used to construct a ChatGPT session.
/// JWT decoding extracts metadata; it does not verify signatures. Credentials
/// must come from the authentication transport or the selected credential store.
struct JWTSession: Decodable, Sendable {
    let email: String?
    let name: String?
    let chatGPTAccountID: String?
    let userID: String?
    let fedramp: Bool
    let issuedAt: Date?
    let expiresAt: Date?
    private let plan: JWTSessionField<String>

    var planType: String? { plan.text }
    var hasPlan: Bool { plan.isPresent }

    private enum CodingKeys: String, CodingKey {
        case email, name
        case accountID = "chatgpt_account_id"
        case plan = "chatgpt_plan_type"
        case issuedAt = "iat"
        case expiresAt = "exp"
        case auth = "https://api.openai.com/auth"
        case profile = "https://api.openai.com/profile"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let auth = JWTSessionField<JWTSessionAuthentication>(container: container, key: .auth)
        let profile = JWTSessionField<JWTSessionProfile>(container: container, key: .profile)

        chatGPTAccountID = auth.selecting(\.accountID, fallback: .init(container: container, key: .accountID)).text
        plan = auth.selecting(\.plan, fallback: .init(container: container, key: .plan))
        email = profile.selecting(\.email, fallback: .init(container: container, key: .email)).text
        name = profile.selecting(\.name, fallback: .init(container: container, key: .name)).text
        userID = auth.value?.userID
        fedramp = auth.value?.fedramp.value == true
        issuedAt = JWTSessionField<Double>(container: container, key: .issuedAt).date
        expiresAt = JWTSessionField<Double>(container: container, key: .expiresAt).date
    }

    init(token: String) throws {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3, !segments[0].isEmpty, !segments[1].isEmpty else {
            throw ChatGPTSessionError.malformedCredentials
        }

        var payload = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload) else {
            throw ChatGPTSessionError.malformedCredentials
        }

        do {
            self = try JSONDecoder().decode(Self.self, from: data)
        } catch {
            // Decoder errors may contain private field values; expose only the domain error.
            throw ChatGPTSessionError.malformedCredentials
        }
    }
}

private struct JWTSessionAuthentication: Decodable, Sendable {
    let accountID: JWTSessionField<String>
    let plan: JWTSessionField<String>
    let chatGPTUserID: JWTSessionField<String>
    let legacyUserID: JWTSessionField<String>
    let fedramp: JWTSessionField<Bool>

    var userID: String? {
        if let userID = chatGPTUserID.text { return userID }
        return legacyUserID.text
    }

    private enum CodingKeys: String, CodingKey {
        case accountID = "chatgpt_account_id"
        case plan = "chatgpt_plan_type"
        case chatGPTUserID = "chatgpt_user_id"
        case legacyUserID = "user_id"
        case fedramp = "chatgpt_account_is_fedramp"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accountID = .init(container: container, key: .accountID)
        plan = .init(container: container, key: .plan)
        chatGPTUserID = .init(container: container, key: .chatGPTUserID)
        legacyUserID = .init(container: container, key: .legacyUserID)
        fedramp = .init(container: container, key: .fedramp)
    }
}

private struct JWTSessionProfile: Decodable, Sendable {
    let email: JWTSessionField<String>
    let name: JWTSessionField<String>

    private enum CodingKeys: String, CodingKey { case email, name }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        email = .init(container: container, key: .email)
        name = .init(container: container, key: .name)
    }
}

/// A malformed authoritative field must not fall back to a legacy value.
private enum JWTSessionField<Value: Decodable & Sendable>: Sendable {
    case missing
    case malformed
    case present(Value)

    var value: Value? {
        guard case let .present(value) = self else { return nil }
        return value
    }

    var isPresent: Bool {
        if case .missing = self { return false }
        return true
    }

    init<Key: CodingKey>(container: KeyedDecodingContainer<Key>, key: Key) {
        guard container.contains(key) else {
            self = .missing
            return
        }
        do {
            self = .present(try container.decode(Value.self, forKey: key))
        } catch {
            self = .malformed
        }
    }

    func selecting<Field: Decodable & Sendable>(
        _ keyPath: KeyPath<Value, JWTSessionField<Field>>,
        fallback: JWTSessionField<Field>
    ) -> JWTSessionField<Field> {
        switch self {
        case .missing:
            return fallback
        case .malformed:
            return .malformed
        case let .present(namespace):
            let field = namespace[keyPath: keyPath]
            return field.isPresent ? field : fallback
        }
    }
}

private extension JWTSessionField where Value == String {
    var text: String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension JWTSessionField where Value == Double {
    var date: Date? {
        guard let seconds = value, seconds.isFinite, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}
