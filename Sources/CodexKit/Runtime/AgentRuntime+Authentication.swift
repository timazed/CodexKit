import Foundation

/// Task-scoped so shared backend instances cannot acquire another runtime's provider.
/// Existing third-party backend protocol requirements remain unchanged.
struct AgentAuthenticationContext: Sendable {
    @TaskLocal static var current: AgentAuthenticationContext?
    let resolve: @Sendable () async throws -> ChatGPTSession
    let recover: @Sendable (String) async throws -> ChatGPTSession
}

extension AgentRuntime {
    func authenticationContext(for initial: ChatGPTSession) -> AgentAuthenticationContext {
        let provider = sessionManager
        return .init(resolve: {
            let current = try await provider.requireSession()
            try Self.validateLease(current, against: initial)
            return current
        }, recover: { previous in
            let before = try await provider.requireSession()
            try Self.validateLease(before, against: initial)
            let recovered = try await provider.recoverUnauthorizedSession(previousAccessToken: previous)
            try Self.validateLease(recovered, against: initial)
            return recovered
        })
    }

    nonisolated static func validateLease(_ current: ChatGPTSession, against initial: ChatGPTSession) throws {
        try Task.checkCancellation()
        guard current.binding == initial.binding else { throw ChatGPTSessionError.accountChanged }
        guard current.lifecycleID == initial.lifecycleID else { throw CancellationError() }
    }

    func validateActiveAuthentication(_ initial: ChatGPTSession) async throws {
        guard let current = await sessionManager.currentSession() else { throw ChatGPTSessionError.disconnected }
        try Self.validateLease(current, against: initial)
    }

    func validateThreadAuthentication(_ thread: AgentThread, session: ChatGPTSession) throws {
        try validateMemoryAuthentication(session)
        if let binding = thread.authenticationBinding {
            guard binding == session.binding else { throw ChatGPTSessionError.accountChanged }
        } else if session.isExternallyManaged {
            throw ChatGPTSessionError.unboundConversation
        }
    }

    func validateMemoryAuthentication(_ session: ChatGPTSession) throws {
        guard let memoryConfiguration else { return }
        if let binding = memoryConfiguration.authenticationBinding {
            guard binding == session.binding else { throw ChatGPTSessionError.accountChanged }
        } else if session.isExternallyManaged {
            throw ChatGPTSessionError.unboundConversation
        }
    }

    func interruptAuthenticatedExecutions() {
        for control in authenticatedExecutionControls.values { control.cancellation.cancel() }
        for execution in activeTurnExecutions.values { execution.cancellation.cancel() }
    }

    /// Snapshot suitable for onboarding/settings. Hosts with custom providers can expose richer state themselves.
    public func authenticationState() async -> ChatGPTAuthenticationState {
        if let manager = sessionManager as? ChatGPTSessionManager { return await manager.authenticationState() }
        let session = await sessionManager.currentSession()
        return .init(status: session == nil ? .disconnected : .connected,
                     externallyManaged: session?.isExternallyManaged ?? false, expiresAt: session?.expiresAt)
    }
}
