#if os(macOS)
import CodexKit
import Foundation

/// UI-free integration example. Persist this preference in the consuming application.
/// A binding contains identifiers, so protect it as account metadata even though it contains no tokens.
enum AuthenticationPreference: Codable {
    case disconnected
    case application
    case external(ChatGPTSessionBinding)
}

@MainActor
final class LocalCodexSessionIntegration {
    let sessions: ChatGPTSessionManager
    let runtime: AgentRuntime
    private let source: CodexLocalSessionSource
    private let preferences: UserDefaults
    private let preferenceKey = "authenticationPreference"

    init(authProvider: ChatGPTAuthProvider,
         effectiveConfiguration: @escaping @Sendable () async throws -> CodexLocalSessionConfiguration,
         stateStore: any RuntimeStateStoring,
         approvalPresenter: any ApprovalPresenting,
         preferences: UserDefaults) throws {
        self.preferences = preferences
        sessions = ChatGPTSessionManager(authProvider: authProvider,
            secureStore: KeychainSessionSecureStore(service: "Example.ApplicationOwnedSession"))
        source = CodexLocalSessionSource(configuration: effectiveConfiguration)
        runtime = try AgentRuntime(configuration: .init(sessionProvider: sessions,
            backend: CodexResponsesBackend(), approvalPresenter: approvalPresenter, stateStore: stateStore))
    }

    /// Call during onboarding/restoration. A failure is presented to the application for its own UX.
    /// This method never starts interactive login automatically.
    func restoreOrDiscover() async throws -> ChatGPTAuthenticationState {
        let preference = try preferences.data(forKey: preferenceKey).map {
            try JSONDecoder().decode(AuthenticationPreference.self, from: $0)
        }
        switch preference {
        case .disconnected:
            return await sessions.authenticationState()
        case .application:
            _ = try await sessions.restore()
        case let .external(binding):
            _ = try await sessions.connectExternalSession(source: source, expectedBinding: binding)
        case nil:
            let session = try await sessions.connectExternalSession(source: source)
            try save(.external(session.binding))
        }
        _ = try await runtime.restore()
        return await runtime.authenticationState()
    }

    /// Invoke only when the application chooses its existing interactive fallback.
    func signInInteractively() async throws {
        _ = try await runtime.signIn()
        try save(.application)
        _ = try await runtime.restore()
    }

    func disconnect() async throws {
        // Retain this choice across launches so discovery does not reconnect immediately.
        try save(.disconnected)
        try await runtime.signOut()
    }

    private func save(_ preference: AuthenticationPreference) throws {
        preferences.set(try JSONEncoder().encode(preference), forKey: preferenceKey)
    }
}
#endif
