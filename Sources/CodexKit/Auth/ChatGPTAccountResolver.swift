import Foundation

private let unknownAccountID = "unknown-account"
private let unknownEmail = "unknown@chatgpt.local"

/// Resolves metadata and checks identity for one decoded ID/access-token pair.
struct ChatGPTAccountResolver {
    let id: ChatGPTSessionMetadata?
    let access: ChatGPTSessionMetadata?

    init(id: ChatGPTSessionMetadata?, access: ChatGPTSessionMetadata?) {
        self.id = id
        self.access = access
    }

    init(idToken: String?, accessToken: String) {
        if let idToken {
            id = try? ChatGPTSessionMetadata(token: idToken)
        } else {
            id = nil
        }
        access = try? ChatGPTSessionMetadata(token: accessToken)
    }

    var hasPlan: Bool { id?.hasPlan == true || access?.hasPlan == true }
    private var userID: String? { id?.userID ?? access?.userID }

    var account: ChatGPTAccount {
        get throws {
            try validateIdentity(id?.chatGPTAccountID, against: access?.chatGPTAccountID)
            try validateIdentity(id?.userID, against: access?.userID)

            let plan: ChatGPTPlanType
            if let id, id.hasPlan {
                plan = .resolve(id.planType)
            } else {
                plan = .resolve(access?.planType)
            }

            return ChatGPTAccount(
                id: id?.chatGPTAccountID ?? access?.chatGPTAccountID ?? unknownAccountID,
                email: id?.email ?? access?.email ?? unknownEmail,
                plan: plan,
                name: id?.name
            )
        }
    }

    func validateAccountIdentity(against previous: ChatGPTAccount) throws {
        let resolved = try account
        guard !resolved.hasPlaceholderID, !previous.hasPlaceholderID else { return }
        try validateIdentity(resolved.id, against: previous.id)
    }

    func validateUserIdentity(against previous: ChatGPTAccountResolver) throws {
        try validateIdentity(userID, against: previous.userID)
    }

    private func validateIdentity(_ candidate: String?, against previous: String?) throws {
        guard let candidate, let previous else { return }
        guard candidate == previous else { throw ChatGPTSessionError.accountChanged }
    }
}

extension ChatGPTAccount {
    var hasPlaceholderID: Bool { id.isEmpty || id == unknownAccountID }
    var hasPlaceholderEmail: Bool { email.isEmpty || email == unknownEmail }
}
