import Foundation

extension AgentRuntime {
    /// Exports the current access-only session without refreshing or reading external credentials.
    /// Returned plaintext is sensitive: use authenticated TLS and encrypted backend storage.
    public func exportSession() async throws -> Data {
        guard let session = await currentSession() else { throw AgentRuntimeError.signedOut() }
        return try ChatGPTSessionTransfer(session: session).exportJSON()
    }

    /// Adopts supplied credentials, like local session reuse, without filesystem discovery or login.
    /// Local validation does not prove provider acceptance. Imported credentials stay in memory;
    /// expiry or rejection requires explicitly importing a replacement.
    @discardableResult
    public func importSession(_ data: Data) async throws -> ChatGPTSession {
        let transfer = try ChatGPTSessionTransfer.importJSON(data)
        return try await useSession(transfer.validatedSession())
    }
}
