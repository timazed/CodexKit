import Foundation

public actor ChatGPTSessionManager {
    private let authProvider: ChatGPTAuthProvider
    private let secureStore: KeychainSessionSecureStore
    private let logger: AgentLogger
    private var session: ChatGPTSession?
    private var generation = UUID()
    private var pendingRefresh: (generation: UUID, task: Task<ChatGPTSession, Error>)?

    public init(
        authProvider: ChatGPTAuthProvider,
        secureStore: KeychainSessionSecureStore,
        logging: AgentLoggingConfiguration = .disabled
    ) {
        self.authProvider = authProvider
        self.secureStore = secureStore
        self.logger = AgentLogger(configuration: logging)
    }

    @discardableResult
    public func restore() throws -> ChatGPTSession? {
        let restored = try secureStore.loadSession()
        invalidatePendingAuthentication()
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
    public func useSession(_ session: ChatGPTSession) throws -> ChatGPTSession {
        try secureStore.saveSession(session)
        invalidatePendingAuthentication()
        self.session = session
        logger.info(
            .auth,
            "Session loaded and persisted.",
            metadata: [
                "account_id": session.account.id,
                "plan": session.account.plan.rawValue,
                "externally_managed": "\(session.isExternallyManaged)"
            ]
        )
        return session
    }

    @discardableResult
    public func signIn() async throws -> ChatGPTSession {
        invalidatePendingAuthentication()
        let startedGeneration = generation
        let signedInSession = try await authProvider.signInInteractively()
        try Task.checkCancellation()
        guard generation == startedGeneration else { throw CancellationError() }
        try secureStore.saveSession(signedInSession)
        invalidatePendingAuthentication()
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
        let startedGeneration = generation
        if let pendingRefresh, pendingRefresh.generation == startedGeneration {
            let refreshed = try await waitForRefresh(pendingRefresh.task)
            try Task.checkCancellation()
            guard generation == startedGeneration else { throw CancellationError() }
            return refreshed
        }
        logger.info(
            .auth,
            "Refreshing session.",
            metadata: [
                "reason": refreshReasonLabel(reason),
                "account_id": current.account.id
            ]
        )
        let authProvider = authProvider
        let task = Task {
            defer {
                if self.pendingRefresh?.generation == startedGeneration { self.pendingRefresh = nil }
            }
            do {
                let refreshed = try await authProvider.refresh(session: current, reason: reason)
                return try self.commitRefresh(refreshed, generation: startedGeneration)
            } catch {
                try Task.checkCancellation()
                throw error
            }
        }
        pendingRefresh = (startedGeneration, task)
        let refreshed = try await waitForRefresh(task)
        guard generation == startedGeneration else { throw CancellationError() }
        logger.info(
            .auth,
            "Session refresh completed.",
            metadata: ["account_id": refreshed.account.id]
        )
        try Task.checkCancellation()
        return refreshed
    }

    public func signOut() async throws {
        let current = session
        invalidatePendingAuthentication()
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
        // Recovery is only valid for the active account, never after sign-out.
        let current = try requireStoredSession()
        logger.warning(
            .auth,
            "Attempting unauthorized-session recovery.",
            metadata: ["had_previous_access_token": "\(previousAccessToken != nil)"]
        )
        if let restored = try secureStore.loadSession(), restored.account.id == current.account.id {
            if let previousAccessToken,
               restored.accessToken != previousAccessToken,
               !restored.requiresRefresh() {
                if restored != session {
                    invalidatePendingAuthentication()
                    session = restored
                }
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

    /// Cancelling a caller stops its wait without cancelling refreshes needed by
    /// other turns. The shared task, rather than any waiter, owns cache cleanup.
    private func waitForRefresh(_ task: Task<ChatGPTSession, Error>) async throws -> ChatGPTSession {
        let values = AsyncThrowingStream<ChatGPTSession, Error> { continuation in
            let waiter = Task {
                do {
                    continuation.yield(try await task.value)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in waiter.cancel() }
        }
        var iterator = values.makeAsyncIterator()
        guard let value = try await iterator.next() else { throw CancellationError() }
        try Task.checkCancellation()
        return value
    }

    private func invalidatePendingAuthentication() {
        generation = UUID()
        pendingRefresh?.task.cancel()
        pendingRefresh = nil
    }

    private func commitRefresh(_ refreshed: ChatGPTSession, generation expected: UUID) throws -> ChatGPTSession {
        guard generation == expected else { throw CancellationError() }
        try secureStore.saveSession(refreshed)
        session = refreshed
        return refreshed
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
