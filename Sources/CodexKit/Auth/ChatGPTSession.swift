import Foundation

public enum ChatGPTPlanType: String, Codable, Hashable, Sendable {
    case free
    case plus
    case pro
    case team
    case business
    case enterprise
    case edu
    case unknown
}

public struct ChatGPTAccount: Codable, Hashable, Sendable {
    public var id: String
    public var email: String
    public var plan: ChatGPTPlanType
    /// The name supplied by the sign-in token, when available.
    public var name: String?

    public init(id: String, email: String, plan: ChatGPTPlanType) {
        self.init(id: id, email: email, plan: plan, name: nil)
    }

    public init(id: String, email: String, plan: ChatGPTPlanType, name: String?) {
        self.id = id
        self.email = email
        self.plan = plan
        self.name = name
    }

    /// The account name with surrounding whitespace removed, or the email when absent or blank.
    public var displayName: String {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return email
        }
        return name
    }
}

public struct ChatGPTSession: Codable, Hashable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var idToken: String?
    public var account: ChatGPTAccount
    public var acquiredAt: Date
    public var expiresAt: Date?
    public var ownership: ChatGPTSessionOwnership
    public var credentialGeneration: String?
    // In-memory epoch; deliberately not serialized. Changes on disconnect/rebinding.
    var lifecycleID: UUID?
    public var isExternallyManaged: Bool {
        get { if case .external = ownership { return true }; return false }
        set { if !newValue { ownership = .application } else if !isExternallyManaged { ownership = .external(nil) } }
    }
    public var binding: ChatGPTSessionBinding {
        if case let .external(binding?) = ownership { return binding }
        return .init(sourceID: isExternallyManaged ? "external:legacy" : "application", accountID: account.id)
    }

    public init(
        accessToken: String,
        refreshToken: String? = nil,
        idToken: String? = nil,
        account: ChatGPTAccount,
        acquiredAt: Date = Date(),
        expiresAt: Date? = nil,
        isExternallyManaged: Bool = false
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.account = account
        self.acquiredAt = acquiredAt
        self.expiresAt = expiresAt
        self.ownership = isExternallyManaged ? .external(nil) : .application
    }

    public init(accessToken: String, account: ChatGPTAccount, binding: ChatGPTSessionBinding,
                expiresAt: Date, acquiredAt: Date = Date(), credentialGeneration: String? = nil) {
        self.init(accessToken: accessToken, account: account, acquiredAt: acquiredAt,
                  expiresAt: expiresAt, isExternallyManaged: true)
        self.ownership = .external(binding)
        self.credentialGeneration = credentialGeneration
    }

    enum CodingKeys: String, CodingKey {
        case accessToken, refreshToken, idToken, account, acquiredAt, expiresAt
        case isExternallyManaged, ownership, credentialGeneration
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try c.decode(String.self, forKey: .accessToken)
        refreshToken = try c.decodeIfPresent(String.self, forKey: .refreshToken)
        idToken = try c.decodeIfPresent(String.self, forKey: .idToken)
        account = try c.decode(ChatGPTAccount.self, forKey: .account)
        acquiredAt = try c.decode(Date.self, forKey: .acquiredAt)
        expiresAt = try c.decodeIfPresent(Date.self, forKey: .expiresAt)
        let external = try c.decodeIfPresent(Bool.self, forKey: .isExternallyManaged) ?? false
        ownership = try c.decodeIfPresent(ChatGPTSessionOwnership.self, forKey: .ownership)
            ?? (external ? .external(nil) : .application)
        credentialGeneration = try c.decodeIfPresent(String.self, forKey: .credentialGeneration)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(accessToken, forKey: .accessToken)
        try c.encodeIfPresent(refreshToken, forKey: .refreshToken)
        try c.encodeIfPresent(idToken, forKey: .idToken)
        try c.encode(account, forKey: .account)
        try c.encode(acquiredAt, forKey: .acquiredAt)
        try c.encodeIfPresent(expiresAt, forKey: .expiresAt)
        try c.encode(isExternallyManaged, forKey: .isExternallyManaged)
        try c.encode(ownership, forKey: .ownership)
        try c.encodeIfPresent(credentialGeneration, forKey: .credentialGeneration)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.accessToken == rhs.accessToken && lhs.refreshToken == rhs.refreshToken && lhs.idToken == rhs.idToken
            && lhs.account == rhs.account && lhs.acquiredAt == rhs.acquiredAt && lhs.expiresAt == rhs.expiresAt
            && lhs.ownership == rhs.ownership && lhs.credentialGeneration == rhs.credentialGeneration
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(accessToken); hasher.combine(refreshToken); hasher.combine(idToken)
        hasher.combine(account); hasher.combine(acquiredAt); hasher.combine(expiresAt)
        hasher.combine(ownership); hasher.combine(credentialGeneration)
    }

    public func requiresRefresh(
        referenceDate: Date = Date(),
        skew: TimeInterval = 120
    ) -> Bool {
        guard let expiresAt else {
            return false
        }
        return expiresAt.timeIntervalSince(referenceDate) <= skew
    }
}

public enum ChatGPTAuthRefreshReason: Sendable {
    case unauthorized
}

// Safe default diagnostics; serialization remains available for app-owned secure storage.
extension ChatGPTSession: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "ChatGPTSession(externallyManaged: \(isExternallyManaged))" }
    public var debugDescription: String { description }
}

extension ChatGPTAccount: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "ChatGPTAccount(redacted)" }
    public var debugDescription: String { description }
}
