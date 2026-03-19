import CodexKit
import Foundation

public struct DemoChatGPTAuthProvider: ChatGPTAuthProviding {
    public init() {}

    public func signInInteractively() async throws -> ChatGPTSession {
        try await Task.sleep(for: .milliseconds(150))
        return ChatGPTSession(
            accessToken: "demo-access-token",
            refreshToken: "demo-refresh-token",
            account: ChatGPTAccount(
                id: "demo-account",
                email: "demo@example.com",
                plan: .plus
            ),
            isExternallyManaged: true
        )
    }

    public func refresh(
        session: ChatGPTSession,
        reason _: ChatGPTAuthRefreshReason
    ) async throws -> ChatGPTSession {
        var refreshed = session
        refreshed.acquiredAt = Date()
        return refreshed
    }

    public func signOut(session _: ChatGPTSession?) async {}
}
