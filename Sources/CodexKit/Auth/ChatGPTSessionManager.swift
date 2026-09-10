import Foundation

public actor ChatGPTSessionManager {
    private let authProvider: ChatGPTAuthProvider
    let secureStore: any ChatGPTSessionStoring
    private let logger: AgentLogger
    var session: ChatGPTSession?
    var generation = UUID()
    var externalSource: (any ChatGPTExternalSessionSource)?
    var credentialOwner: (any ChatGPTSessionOwnerRenewing)?
    var rejectedAccessToken: String?
    var authenticationFailure: ChatGPTSessionError?
    let now: @Sendable () -> Date
    let renewalTimeout: Duration
    private var pendingRefresh: (generation: UUID, task: Task<ChatGPTSession, Error>)?

    public init(
        authProvider: ChatGPTAuthProvider,
        secureStore: KeychainSessionSecureStore,
        logging: AgentLoggingConfiguration = .disabled
    ) {
        self.authProvider = authProvider
        self.secureStore = secureStore
        self.logger = AgentLogger(configuration: logging)
        self.now = { Date() }
        self.renewalTimeout = .seconds(15)
    }

    public init(authProvider: ChatGPTAuthProvider, sessionStore: any ChatGPTSessionStoring,
                logging: AgentLoggingConfiguration = .disabled,
                now: @escaping @Sendable () -> Date = { Date() },
                renewalTimeout: Duration = .seconds(15)) {
        self.authProvider = authProvider
        self.secureStore = sessionStore
        self.logger = AgentLogger(configuration: logging)
        self.now = now
        self.renewalTimeout = max(.milliseconds(1), renewalTimeout)
    }

    @discardableResult
    public func restore() async throws -> ChatGPTSession? {
        // Explicit external bindings take precedence; restoration must not switch modes.
        if externalSource != nil { return try await requireSession() }
        var restored = try secureStore.loadSession()
        if restored?.isExternallyManaged == true {
            // Remove only the application's obsolete copy, never the external source.
            try secureStore.deleteSession()
            restored = nil
            authenticationFailure = .reconnectRequired
        }
        invalidatePendingAuthentication()
        if restored != nil { authenticationFailure = nil }
        rejectedAccessToken = nil
        restored?.lifecycleID = generation
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
        if case let .external(binding?) = session.ownership, binding.accountID != session.account.id {
            throw ChatGPTSessionError.accountChanged
        }
        if !session.isExternallyManaged { try secureStore.saveSession(session) }
        invalidatePendingAuthentication()
        externalSource = nil
        credentialOwner = nil
        authenticationFailure = nil
        rejectedAccessToken = nil
        var accepted = session
        accepted.lifecycleID = generation
        if accepted.isExternallyManaged { accepted.refreshToken = nil; accepted.idToken = nil }
        self.session = accepted
        logger.info(
            .auth,
            "Session loaded.",
            metadata: [
                "externally_managed": "\(session.isExternallyManaged)"
            ]
        )
        return accepted
    }

    @discardableResult
    public func signIn() async throws -> ChatGPTSession {
        invalidatePendingAuthentication()
        let startedGeneration = generation
        let signedInSession = try await authProvider.signInInteractively()
        try Task.checkCancellation()
        guard generation == startedGeneration else { throw CancellationError() }
        if !signedInSession.isExternallyManaged { try secureStore.saveSession(signedInSession) }
        invalidatePendingAuthentication()
        externalSource = nil
        credentialOwner = nil
        authenticationFailure = nil
        rejectedAccessToken = nil
        var accepted = signedInSession
        accepted.lifecycleID = generation
        session = accepted
        logger.info(
            .auth,
            "Interactive sign-in completed and session persisted.",
            metadata: [:]
        )
        return accepted
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
            ]
        )
        let authProvider = authProvider
        let task = Task {
            defer {
                if self.pendingRefresh?.generation == startedGeneration { self.pendingRefresh = nil }
            }
            do {
                let refreshed: ChatGPTSession
                if current.isExternallyManaged {
                    refreshed = try await self.renewExternalSession(current, generation: startedGeneration)
                } else {
                    refreshed = try await authProvider.refresh(session: current, reason: reason)
                }
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
            metadata: [:]
        )
        try Task.checkCancellation()
        return refreshed
    }

    public func signOut() async throws {
        let current = session
        let external = current?.isExternallyManaged == true || externalSource != nil
        invalidatePendingAuthentication()
        session = nil
        externalSource = nil
        credentialOwner = nil
        authenticationFailure = .disconnected
        rejectedAccessToken = nil
        if !external {
            try secureStore.deleteSession()
            await authProvider.signOut(session: current)
        }
        logger.info(
            .auth,
            "Session signed out.",
            metadata: [
                "had_session": "\(current != nil)",
            ]
        )
    }

    public func requireSession() async throws -> ChatGPTSession {
        guard let session else {
            if let authenticationFailure, authenticationFailure != .disconnected { throw authenticationFailure }
            throw AgentRuntimeError.signedOut()
        }
        if session.isExternallyManaged, externalSource != nil {
            let expected = generation
            let resolved = try await resolveExternalSession(session, generation: expected)
            if resolved.accessToken == rejectedAccessToken || resolved.requiresRefresh(referenceDate: now()) { return try await refresh(reason: .unauthorized) }
            self.session = resolved
            return resolved
        }
        if session.requiresRefresh(referenceDate: now()) {
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
        if current.isExternallyManaged {
            rejectedAccessToken = previousAccessToken ?? current.accessToken
            if let previousAccessToken, current.accessToken != previousAccessToken,
               !current.requiresRefresh(referenceDate: now()) { return try await requireSession() }
            return try await refresh(reason: .unauthorized)
        }
        if var restored = try secureStore.loadSession(), !restored.isExternallyManaged, restored.binding == current.binding {
            if let previousAccessToken,
               restored.accessToken != previousAccessToken,
               !restored.requiresRefresh(referenceDate: now()) {
                if restored != session {
                    invalidatePendingAuthentication()
                    restored.lifecycleID = current.lifecycleID
                    session = restored
                }
                logger.info(
                    .auth,
                    "Recovered session from secure store after unauthorized response.",
                    metadata: [:]
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

    func invalidatePendingAuthentication() {
        generation = UUID()
        pendingRefresh?.task.cancel()
        pendingRefresh = nil
    }

    private func commitRefresh(_ refreshed: ChatGPTSession, generation expected: UUID) throws -> ChatGPTSession {
        guard generation == expected else { throw CancellationError() }
        guard refreshed.binding == session?.binding else { throw ChatGPTSessionError.accountChanged }
        if !refreshed.isExternallyManaged { try secureStore.saveSession(refreshed) }
        var accepted = refreshed
        accepted.lifecycleID = session?.lifecycleID ?? generation
        session = accepted
        authenticationFailure = nil
        rejectedAccessToken = nil
        return accepted
    }

    private func requireStoredSession() throws -> ChatGPTSession {
        guard let session else {
            if let authenticationFailure, authenticationFailure != .disconnected { throw authenticationFailure }
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
