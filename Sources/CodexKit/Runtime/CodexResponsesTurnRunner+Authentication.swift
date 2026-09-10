import Foundation

extension CodexResponsesTurnRunner {
    func consumeAuthenticatedStream(
        request: URLRequest, lease: ChatGPTSession,
        state: inout TurnRunState, retryState: inout RetryAttemptState
    ) async throws -> TurnPassDisposition {
        do {
            return try await consumeEventStream(request: request, state: &state, retryState: &retryState)
        } catch {
            guard let authenticationContext, AgentRuntime.isUnauthorizedError(error),
                  !retryState.hasVisibleOutput, !retryState.hasNonReplayableOutput else { throw error }
            let refreshed = try await authenticationContext.recover(retryState.accessTokenUsed ?? lease.accessToken)
            var retry = request
            retry.setValue("Bearer \(refreshed.accessToken)", forHTTPHeaderField: "Authorization")
            retry.setValue(refreshed.account.id, forHTTPHeaderField: "ChatGPT-Account-ID")
            // Only the rejected HTTP pass is replayed. Completed tools and earlier passes remain intact.
            do { return try await consumeEventStream(request: retry, state: &state, retryState: &retryState) }
            catch {
                if AgentRuntime.isUnauthorizedError(error), let failure = error as? AgentRuntimeError {
                    throw AgentRuntimeError(code: "authentication_recovery_exhausted",
                        message: "Authentication was rejected after renewal. Reconnect to continue.",
                        http: failure.http, interruption: failure.interruption)
                }
                throw error
            }
        }
    }
}
