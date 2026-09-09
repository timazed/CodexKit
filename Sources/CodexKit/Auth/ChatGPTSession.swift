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
    public var isExternallyManaged: Bool

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
        self.isExternallyManaged = isExternallyManaged
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
