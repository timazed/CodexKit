import Foundation

/// The runtime's authentication boundary. Hosts own refresh synchronization,
/// account replacement, and credential storage when supplying an implementation.
public protocol AgentSessionProviding: Sendable {
    func currentSession() async -> ChatGPTSession?
    func restore() async throws -> ChatGPTSession?
    func requireSession() async throws -> ChatGPTSession
    func recoverUnauthorizedSession(previousAccessToken: String?) async throws -> ChatGPTSession
}

public extension AgentSessionProviding {
    func restore() async throws -> ChatGPTSession? { await currentSession() }

    func requireSession() async throws -> ChatGPTSession {
        try Task.checkCancellation()
        guard let session = await currentSession() else { throw AgentRuntimeError.signedOut() }
        try Task.checkCancellation()
        return session
    }

    func recoverUnauthorizedSession(previousAccessToken: String?) async throws -> ChatGPTSession {
        throw AgentRuntimeError.unauthorized()
    }
}

/// Optional interactive/session-management capabilities. A read-only provider
/// can omit these; the corresponding runtime actions then fail explicitly.
public protocol AgentSessionManaging: AgentSessionProviding {
    func signIn() async throws -> ChatGPTSession
    func useSession(_ session: ChatGPTSession) async throws -> ChatGPTSession
    func signOut() async throws
}

extension ChatGPTSessionManager: AgentSessionManaging {}

extension AgentRuntimeError {
    static func sessionManagementUnsupported() -> Self {
        .init(code: .sessionManagementUnsupported, message: "This session provider is managed by the host app.")
    }
}
