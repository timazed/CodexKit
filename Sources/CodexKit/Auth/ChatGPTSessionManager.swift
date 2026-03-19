import Foundation

public actor ChatGPTSessionManager {
    private let authProvider: any ChatGPTAuthProviding
    private let secureStore: any SessionSecureStoring
    private var session: ChatGPTSession?

    public init(
        authProvider: any ChatGPTAuthProviding,
        secureStore: any SessionSecureStoring
    ) {
        self.authProvider = authProvider
        self.secureStore = secureStore
    }

    @discardableResult
    public func restore() throws -> ChatGPTSession? {
        let restored = try secureStore.loadSession()
        session = restored
        return restored
    }

    public func currentSession() -> ChatGPTSession? {
        session
    }

    @discardableResult
    public func signIn() async throws -> ChatGPTSession {
        let signedInSession = try await authProvider.signInInteractively()
        try secureStore.saveSession(signedInSession)
        session = signedInSession
        return signedInSession
    }

    @discardableResult
    public func refresh(reason: ChatGPTAuthRefreshReason) async throws -> ChatGPTSession {
        let current = try requireStoredSession()
        let refreshed = try await authProvider.refresh(session: current, reason: reason)
        try secureStore.saveSession(refreshed)
        session = refreshed
        return refreshed
    }

    public func signOut() async throws {
        let current = session
        session = nil
        try secureStore.deleteSession()
        await authProvider.signOut(session: current)
    }

    public func requireSession() async throws -> ChatGPTSession {
        guard let session else {
            throw AgentRuntimeError.signedOut()
        }
        if session.requiresRefresh() {
            return try await refresh(reason: .unauthorized)
        }
        return session
    }

    private func requireStoredSession() throws -> ChatGPTSession {
        guard let session else {
            throw AgentRuntimeError.signedOut()
        }
        return session
    }
}
