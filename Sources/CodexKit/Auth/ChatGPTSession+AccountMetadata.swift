import Foundation

extension TokenResponse {
    func makeSession(fallbackRefreshToken: String? = nil) throws -> ChatGPTSession {
        let resolver = ChatGPTAccountResolver(idToken: idToken, accessToken: accessToken)
        return try makeSession(resolver: resolver, fallbackRefreshToken: fallbackRefreshToken)
    }

    func refreshedSession(previous: ChatGPTSession) throws -> ChatGPTSession {
        let previousResolver = ChatGPTAccountResolver(idToken: previous.idToken, accessToken: previous.accessToken)
        let refreshedResolver = ChatGPTAccountResolver(idToken: idToken, accessToken: accessToken)
        try refreshedResolver.validateAccountIdentity(against: previous.account)
        try refreshedResolver.validateUserIdentity(against: previousResolver)
        var result = try makeSession(resolver: refreshedResolver, fallbackRefreshToken: previous.refreshToken)

        if result.account.hasPlaceholderID {
            result.account.id = previous.account.id
        }
        if result.account.hasPlaceholderEmail {
            result.account.email = previous.account.email
        }
        if !refreshedResolver.hasPlan {
            result.account.plan = previous.account.plan
        }
        result.account.name = result.account.name ?? previous.account.name
        result.ownership = previous.ownership
        result.credentialGeneration = previous.credentialGeneration
        return result
    }

    private func makeSession(
        resolver: ChatGPTAccountResolver,
        fallbackRefreshToken: String?
    ) throws -> ChatGPTSession {
        ChatGPTSession(
            accessToken: accessToken,
            refreshToken: refreshToken ?? fallbackRefreshToken,
            idToken: idToken,
            account: try resolver.account,
            acquiredAt: resolver.access?.issuedAt ?? Date(),
            expiresAt: resolver.access?.expiresAt
        )
    }
}

extension ChatGPTSession {
    /// Only fills gaps; a cold reopen never replaces valid host metadata or credentials.
    func repairingAccountMetadata() throws -> ChatGPTSession {
        guard !isExternallyManaged else { return self }
        let resolver = ChatGPTAccountResolver(idToken: idToken, accessToken: accessToken)
        try resolver.validateAccountIdentity(against: account)
        let resolved = try resolver.account

        var result = self
        if account.hasPlaceholderID {
            result.account.id = resolved.id
        }
        if account.hasPlaceholderEmail {
            result.account.email = resolved.email
        }
        if account.plan == .unknown {
            result.account.plan = resolved.plan
        }
        let savedName = account.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if savedName.isEmpty {
            result.account.name = resolved.name ?? account.name
        }
        return result
    }
}
