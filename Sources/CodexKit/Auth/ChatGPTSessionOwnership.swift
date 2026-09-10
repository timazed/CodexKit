import Foundation

/// Non-secret identity used to prevent credentials and conversations crossing accounts.
public struct ChatGPTSessionBinding: Codable, Hashable, Sendable {
    public let sourceID: String
    public let accountID: String
    public let userID: String?

    public init(sourceID: String, accountID: String, userID: String? = nil) {
        self.sourceID = sourceID
        self.accountID = accountID
        self.userID = userID
    }
}

public enum ChatGPTSessionOwnership: Codable, Hashable, Sendable {
    case application
    /// Legacy external sessions have no discoverable source and require host replacement.
    case external(ChatGPTSessionBinding?)
}

public enum ChatGPTSessionError: String, Error, Codable, Sendable, LocalizedError {
    case missingCredentials
    case accessDenied
    case storageUnavailable
    case malformedCredentials
    case unsupportedStorage
    case unsupportedAuthentication
    case configurationChanged
    case accountChanged
    case expiredCredentials
    case reconnectRequired
    case revokedCredentials
    case transientFailure
    case disconnected
    case unboundConversation

    public var errorDescription: String? {
        switch self {
        case .missingCredentials: "No credentials are available from the selected source."
        case .accessDenied: "Access to the selected credential source was denied."
        case .storageUnavailable: "The selected credential store is unavailable."
        case .malformedCredentials: "The selected source contains invalid credentials."
        case .unsupportedStorage: "The selected credential storage mode is not supported."
        case .unsupportedAuthentication: "The selected authentication mode is not compatible."
        case .configurationChanged: "The bound credential source configuration changed. Reconnect to continue."
        case .accountChanged: "The credential account or workspace changed. Reconnect to continue."
        case .expiredCredentials: "The selected access token has expired."
        case .reconnectRequired: "The credential owner must renew authentication before continuing."
        case .revokedCredentials: "The credential owner reports that authentication was revoked."
        case .transientFailure: "Authentication is temporarily unavailable. Try again later."
        case .disconnected: "The application has disconnected this session."
        case .unboundConversation: "This conversation has no verified account binding. Create a new conversation."
        }
    }
}

/// No tokens or private account identifiers are exposed through this state.
public struct ChatGPTAuthenticationState: Sendable, Equatable {
    public enum Status: String, Sendable { case disconnected, connected, reconnectRequired, unavailable }
    public let status: Status
    public let externallyManaged: Bool
    public let expiresAt: Date?
    public let failure: ChatGPTSessionError?

    public init(status: Status, externallyManaged: Bool, expiresAt: Date? = nil, failure: ChatGPTSessionError? = nil) {
        self.status = status
        self.externallyManaged = externallyManaged
        self.expiresAt = expiresAt
        self.failure = failure
    }
}

/// Read-only by construction. Implementations must never refresh or mutate owner credentials.
public protocol ChatGPTExternalSessionSource: Sendable {
    func resolve() async throws -> ChatGPTSession
}

/// An optional, explicitly integrated credential owner. It receives no refresh token.
/// Throw `transientFailure` or `revokedCredentials` when those outcomes are known.
public protocol ChatGPTSessionOwnerRenewing: Sendable {
    func requestRenewal(for binding: ChatGPTSessionBinding) async throws
}

public protocol ChatGPTSessionStoring: Sendable {
    func loadSession() throws -> ChatGPTSession?
    func saveSession(_ session: ChatGPTSession) throws
    func deleteSession() throws
}

extension KeychainSessionSecureStore: ChatGPTSessionStoring {}

extension ChatGPTSessionBinding {
    var cacheKey: String {
        [sourceID, accountID, userID ?? ""].map { "\($0.utf8.count):\($0)" }.joined()
    }
}

extension ChatGPTSessionBinding: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "ChatGPTSessionBinding(redacted)" }
    public var debugDescription: String { description }
}
