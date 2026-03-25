import Foundation

public actor ChatGPTSessionManager {
    private let authProvider: any ChatGPTAuthProviding
    private let secureStore: any SessionSecureStoring
    private let logger: AgentLogger
    private var session: ChatGPTSession?

    public init(
        authProvider: any ChatGPTAuthProviding,
        secureStore: any SessionSecureStoring,
        logging: AgentLoggingConfiguration = .disabled
    ) {
        self.authProvider = authProvider
        self.secureStore = secureStore
        self.logger = AgentLogger(configuration: logging)
    }

    @discardableResult
    public func restore() throws -> ChatGPTSession? {
        let restored = try secureStore.loadSession()
        session = restored
        logger.debug(
            .auth,
            "Secure-store session restore completed.",
            metadata: [
                "restored": "\(restored != nil)",
                "requires_refresh": "\(restored?.requiresRefresh() ?? false)"
            ]
        )
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
        logger.info(
            .auth,
            "Interactive sign-in completed and session persisted.",
            metadata: [
                "account_id": signedInSession.account.id,
                "plan": signedInSession.account.plan.rawValue
            ]
        )
        return signedInSession
    }

    @discardableResult
    public func refresh(reason: ChatGPTAuthRefreshReason) async throws -> ChatGPTSession {
        let current = try requireStoredSession()
        logger.info(
            .auth,
            "Refreshing session.",
            metadata: [
                "reason": refreshReasonLabel(reason),
                "account_id": current.account.id
            ]
        )
        let refreshed = try await authProvider.refresh(session: current, reason: reason)
        try secureStore.saveSession(refreshed)
        session = refreshed
        logger.info(
            .auth,
            "Session refresh completed.",
            metadata: ["account_id": refreshed.account.id]
        )
        return refreshed
    }

    public func signOut() async throws {
        let current = session
        session = nil
        try secureStore.deleteSession()
        await authProvider.signOut(session: current)
        logger.info(
            .auth,
            "Session signed out.",
            metadata: [
                "had_session": "\(current != nil)",
                "account_id": current?.account.id ?? ""
            ]
        )
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

    public func recoverUnauthorizedSession(
        previousAccessToken: String?
    ) async throws -> ChatGPTSession {
        logger.warning(
            .auth,
            "Attempting unauthorized-session recovery.",
            metadata: ["had_previous_access_token": "\(previousAccessToken != nil)"]
        )
        if let restored = try secureStore.loadSession() {
            session = restored
            if let previousAccessToken,
               restored.accessToken != previousAccessToken,
               !restored.requiresRefresh() {
                logger.info(
                    .auth,
                    "Recovered session from secure store after unauthorized response.",
                    metadata: ["account_id": restored.account.id]
                )
                return restored
            }
        }

        return try await refresh(reason: .unauthorized)
    }

    private func requireStoredSession() throws -> ChatGPTSession {
        guard let session else {
            throw AgentRuntimeError.signedOut()
        }
        return session
    }

    private func refreshReasonLabel(
        _ reason: ChatGPTAuthRefreshReason
    ) -> String {
        switch reason {
        case .unauthorized:
            return "unauthorized"
        }
    }
}
