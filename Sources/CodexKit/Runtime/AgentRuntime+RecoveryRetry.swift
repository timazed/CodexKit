import CryptoKit
import Foundation

extension AgentRuntime {
    /// A deliberate host/user action creates ONE linked successor with a new bounded budget.
    /// Persist retryActionID in host state before calling. Repeating it completes/returns the same successor.
    /// Suspended work with budget remaining must be resumed. Cancelled operations cannot be retried here.
    public func retryStructuredRecovery(_ handle: AgentStructuredRecoveryHandle, retryActionID: UUID,
        store: AgentStructuredRecoveryStore, maximumAttempts: Int = 3,
        selection: AgentRecoveryRetrySelection = .preserve, expiresAt: Date? = nil,
        retryPolicy: AgentRecoveryRetryPolicy? = nil) async throws -> AgentStructuredRecoveryHandle {
        try Task.checkCancellation()
        guard (1...1_000).contains(maximumAttempts) else { throw AgentRecoveryError.attemptsExhausted }
        let lease = try store.acquire(handle)
        defer { withExtendedLifetime(lease) {} }
        var previous = try store.load(handle)
        let session = try await recoverySession(for: previous)
        let lifecycle = try store.lifecycle(handle)
        guard previous.state != .cancelled, lifecycle?.state != .cancelled else { throw AgentRecoveryError.cancelled }
        guard previous.completedPayload == nil else { throw AgentRecoveryError.retryNotAllowed }
        let exhausted = previous.attemptsUsed >= previous.maximumAttempts
        let expired = previous.expiresAt.map { $0 <= Date() } ?? false
        guard exhausted || previous.state == .failed || expired || previous.blocker == .configurationUnavailable else {
            throw AgentRecoveryError.retryNotAllowed
        }
        let policy = retryPolicy ?? previous.retryPolicy ?? .default
        let successor: AgentStructuredRecoveryHandle
        if let id = previous.successorID {
            guard previous.successorActionID == retryActionID else { throw AgentRecoveryError.retryAlreadyCreated }
            guard previous.successorMaximumAttempts == maximumAttempts, previous.successorSelection == selection,
                  previous.successorExpiresAt == expiresAt, previous.successorPolicy == policy else {
                throw AgentRecoveryError.retryConfigurationMismatch
            }
            successor = .init(id: id)
        } else {
            let digest = SHA256.hash(data: Data((handle.id.uuidString + ":" + retryActionID.uuidString).utf8))
            let b = Array(digest.prefix(16))
            successor = .init(id: UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                                               b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15])))
            previous.successorID = successor.id; previous.successorActionID = retryActionID
            previous.successorMaximumAttempts = maximumAttempts; previous.successorSelection = selection
            previous.successorExpiresAt = expiresAt; previous.successorPolicy = policy
            try store.save(previous)
        }
        let successorLease = try store.acquire(successor)
        defer { withExtendedLifetime(successorLease) {} }
        if try store.disposition(successor) != nil { return successor }
        if FileManager.default.fileExists(atPath: store.url(successor).path) {
            let existing = try store.load(successor)
            guard existing.previousOperationID == handle.id, existing.retryActionID == retryActionID else {
                throw AgentRecoveryError.stateInvalid
            }
            return successor
        }
        var request = previous.request
        var thread = previous.thread
        var prepared = previous.preparedRequest
        if selection == .reselect || prepared == nil {
            guard let supporting = backend as? any AgentBackendStructuredRecoverySupporting else { throw AgentRecoveryError.unsupportedBackend }
            if selection == .reselect {
                request.resolvedModelSelection = nil
                thread.configuration = previous.baselineConfiguration
                (request, thread) = try await resolveRequestConfiguration(request, thread: thread,
                    responseFormat: previous.format, session: session)
            }
            let adapter = try await supporting.structuredRecoveryAdapter
            guard adapter.backend.configuration.baseURL == previous.endpoint else { throw ChatGPTSessionError.configurationChanged }
            prepared = try await adapter.prepare(thread: thread, request: request, instructions: previous.instructions,
                format: previous.format, session: session)
        }
        try await validateActiveAuthentication(session)
        var record = AgentStructuredRecoveryRecord(handle: successor, binding: previous.binding,
            thread: thread, request: request, instructions: previous.instructions, format: previous.format,
            endpoint: previous.endpoint, enableReasoningSummaries: prepared?.enableReasoningSummaries ?? previous.enableReasoningSummaries,
            maximumAttempts: maximumAttempts, expiresAt: expiresAt)
        record.preparedRequest = prepared; record.retryPolicy = policy; record.createdAt = Date()
        record.hostJobID = previous.hostJobID; record.inputRevision = previous.inputRevision; record.scope = previous.scope
        record.contractVersion = previous.contractVersion; record.previousOperationID = handle.id
        record.rootOperationID = previous.rootOperationID ?? handle.id; record.retryActionID = retryActionID
        record.baselineConfiguration = previous.baselineConfiguration
        try store.save(record)
        logger.recovery("operation.manual_retry_created", record: record)
        return successor
    }
}
