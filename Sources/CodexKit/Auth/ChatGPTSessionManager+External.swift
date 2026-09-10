import Foundation

extension ChatGPTSessionManager {
    /// Explicit opt-in. Hosts persist the returned binding and their disconnected preference,
    /// then supply the expected binding on restoration. No external tokens are persisted.
    @discardableResult
    public func connectExternalSession(
        source: any ChatGPTExternalSessionSource,
        expectedBinding: ChatGPTSessionBinding? = nil,
        owner: (any ChatGPTSessionOwnerRenewing)? = nil
    ) async throws -> ChatGPTSession {
        invalidatePendingAuthentication()
        let expected = generation
        let candidate: ChatGPTSession
        do { candidate = try await source.resolve() }
        catch { throw recordExternalFailure(error, generation: expected) }
        try Task.checkCancellation()
        guard expected == generation else { throw CancellationError() }
        guard case let .external(binding?) = candidate.ownership, binding.accountID == candidate.account.id else {
            throw ChatGPTSessionError.unsupportedAuthentication
        }
        if let expectedBinding, expectedBinding != binding { throw ChatGPTSessionError.accountChanged }
        externalSource = source
        credentialOwner = owner
        var accepted = candidate
        accepted.refreshToken = nil
        accepted.idToken = nil
        accepted.lifecycleID = generation
        session = accepted
        authenticationFailure = nil
        rejectedAccessToken = nil
        return try await requireSession()
    }

    public func authenticationState() -> ChatGPTAuthenticationState {
        let external = session?.isExternallyManaged == true || externalSource != nil
        if let failure = authenticationFailure {
            let unavailable: Set<ChatGPTSessionError> = [.transientFailure, .accessDenied, .storageUnavailable]
            return .init(status: failure == .disconnected ? .disconnected :
                (unavailable.contains(failure) ? .unavailable : .reconnectRequired),
                externallyManaged: external, expiresAt: session?.expiresAt, failure: failure)
        }
        return .init(status: session == nil ? .disconnected : .connected,
                     externallyManaged: external, expiresAt: session?.expiresAt)
    }

    func resolveExternalSession(_ previous: ChatGPTSession, generation expected: UUID) async throws -> ChatGPTSession {
        guard let externalSource else {
            throw recordExternalFailure(ChatGPTSessionError.reconnectRequired, generation: expected)
        }
        do {
            var candidate = try await externalSource.resolve()
            try Task.checkCancellation()
            guard generation == expected else { throw CancellationError() }
            guard candidate.binding.sourceID == previous.binding.sourceID else { throw ChatGPTSessionError.configurationChanged }
            guard candidate.isExternallyManaged, candidate.binding == previous.binding,
                  candidate.account.id == previous.account.id else { throw ChatGPTSessionError.accountChanged }
            guard candidate.expiresAt != nil else { throw ChatGPTSessionError.malformedCredentials }
            candidate.refreshToken = nil
            candidate.idToken = nil
            candidate.lifecycleID = expected
            if candidate.accessToken != rejectedAccessToken { authenticationFailure = nil }
            return candidate
        } catch { throw recordExternalFailure(error, generation: expected) }
    }

    func renewExternalSession(_ previous: ChatGPTSession, generation expected: UUID) async throws -> ChatGPTSession {
        let reread = try await resolveExternalSession(previous, generation: expected)
        if reread.accessToken != previous.accessToken, !reread.requiresRefresh(referenceDate: now()) { return reread }
        guard let credentialOwner else {
            throw recordExternalFailure(ChatGPTSessionError.reconnectRequired, generation: expected)
        }
        do {
            try await requestOwnerRenewal(credentialOwner, binding: previous.binding)
            try Task.checkCancellation()
            guard generation == expected else { throw CancellationError() }
            let renewed = try await resolveExternalSession(previous, generation: expected)
            guard renewed.accessToken != previous.accessToken, !renewed.requiresRefresh(referenceDate: now()) else {
                throw ChatGPTSessionError.reconnectRequired
            }
            return renewed
        } catch { throw recordExternalFailure(error, generation: expected) }
    }

    private func requestOwnerRenewal(_ owner: any ChatGPTSessionOwnerRenewing, binding: ChatGPTSessionBinding) async throws {
        // Unstructured workers let timeout/cancellation finish even if an injected owner ignores cancellation.
        // Late results still cannot commit because every resolution checks the manager generation.
        let timeout = renewalTimeout
        let stream = AsyncThrowingStream<Bool, Error> { continuation in
            let worker = Task {
                do {
                    try await owner.requestRenewal(for: binding)
                    continuation.yield(true)
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            let timer = Task {
                do {
                    try await Task.sleep(for: timeout)
                    continuation.finish(throwing: ChatGPTSessionError.transientFailure)
                } catch { }
            }
            continuation.onTermination = { _ in worker.cancel(); timer.cancel() }
        }
        var iterator = stream.makeAsyncIterator()
        guard try await iterator.next() == true else { throw CancellationError() }
        try Task.checkCancellation()
    }

    func recordExternalFailure(_ error: Error, generation expected: UUID) -> Error {
        guard generation == expected, !(error is CancellationError), !Task.isCancelled else { return CancellationError() }
        // Never include a store/provider's raw error, which can contain tokens or paths.
        let failure = (error as? ChatGPTSessionError) ?? .transientFailure
        authenticationFailure = failure
        if [.accountChanged, .configurationChanged, .missingCredentials, .revokedCredentials].contains(failure) {
            session = nil
        }
        return failure
    }
}
