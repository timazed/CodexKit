import CodexKit
import Foundation

public func DemoChatGPTAuthProvider() -> ChatGPTAuthProvider {
    try! ChatGPTAuthProvider(method: .oauth)
}

public func demoSession(
    accessToken: String = "demo-access-token"
) -> ChatGPTSession {
    ChatGPTSession(
        accessToken: accessToken,
        refreshToken: "demo-refresh-token",
        account: ChatGPTAccount(
            id: "demo-account",
            email: "demo@example.com",
            plan: .plus
        ),
        acquiredAt: Date(),
        expiresAt: Date().addingTimeInterval(3600),
        isExternallyManaged: false
    )
}
