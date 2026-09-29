import Foundation

/// Shared by the Responses and Images endpoints; never records credentials.
enum CodexRequestAuthentication {
    static func apply(to request: inout URLRequest, session: ChatGPTSession) {
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(session.account.id, forHTTPHeaderField: "ChatGPT-Account-ID")
    }
}
