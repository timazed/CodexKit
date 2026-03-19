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
        let current = try requireSession()
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

    public func requireSession() throws -> ChatGPTSession {
        guard let session else {
            throw AssistantRuntimeError.signedOut()
        }
        return session
    }
}
