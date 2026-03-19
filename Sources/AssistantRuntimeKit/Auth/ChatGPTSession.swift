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

    public init(id: String, email: String, plan: ChatGPTPlanType) {
        self.id = id
        self.email = email
        self.plan = plan
    }
}

public struct ChatGPTSession: Codable, Hashable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var account: ChatGPTAccount
    public var acquiredAt: Date
    public var expiresAt: Date?
    public var isExternallyManaged: Bool

    public init(
        accessToken: String,
        refreshToken: String? = nil,
        account: ChatGPTAccount,
        acquiredAt: Date = Date(),
        expiresAt: Date? = nil,
        isExternallyManaged: Bool = false
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.account = account
        self.acquiredAt = acquiredAt
        self.expiresAt = expiresAt
        self.isExternallyManaged = isExternallyManaged
    }
}

public enum ChatGPTAuthRefreshReason: Sendable {
    case unauthorized
}

public protocol ChatGPTAuthProviding: Sendable {
    func signInInteractively() async throws -> ChatGPTSession
    func refresh(
        session: ChatGPTSession,
        reason: ChatGPTAuthRefreshReason
    ) async throws -> ChatGPTSession
    func signOut(session: ChatGPTSession?) async
}
