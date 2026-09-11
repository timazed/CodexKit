import Foundation

extension AgentRuntime {
    /// Account-bound, read-only observation, including during an active send. No authentication renewal or generation.
    public func structuredRecoveryStatus(_ handle: AgentStructuredRecoveryHandle,
        store: AgentStructuredRecoveryStore) async throws -> AgentStructuredRecoveryStatus {
        guard let session = await sessionManager.currentSession() else {
            return .init(state: .interrupted, operationID: handle.id, blocker: .authenticationRequired)
        }
        if let disposition = try store.disposition(handle) {
            guard session.binding == disposition.binding else {
                return .init(state: .interrupted, operationID: handle.id, blocker: .accountMismatch)
            }
            return disposition.status
        }
        var record = try store.load(handle)
        guard session.binding == record.binding else {
            return .init(state: .interrupted, operationID: handle.id, blocker: .accountMismatch)
        }
        if record.state == .running, try !store.isExecuting(handle) { record.state = .interrupted }
        return record.snapshot(lifecycle: try store.lifecycle(handle))
    }

    /// Returns original, validated bytes for host-controlled decoding or schema migration. Never generates.
    public func structuredRecoveryReceipt(_ handle: AgentStructuredRecoveryHandle,
        store: AgentStructuredRecoveryStore) async throws -> AgentStructuredRecoveryReceipt {
        try Task.checkCancellation()
        let record = try store.load(handle)
        let session = try await recoverySession(for: record)
        guard record.state != .cancelled, try store.lifecycle(handle)?.state != .cancelled else {
            throw AgentRecoveryError.cancelled
        }
        let receipt = try AgentStructuredRecoveryReceipt(record: record)
        try await validateActiveAuthentication(session)
        try Task.checkCancellation()
        if try store.lifecycle(handle)?.state == .cancelled { throw AgentRecoveryError.cancelled }
        logger.recovery("receipt.retrieved", record: record)
        return receipt
    }

    /// Stops the current execution without resetting its budget. Reopening is an explicit new lifecycle owner.
    public func suspendStructuredRecovery(_ handle: AgentStructuredRecoveryHandle,
        store: AgentStructuredRecoveryStore) async throws {
        let record = try store.load(handle)
        _ = try await recoverySession(for: record)
        guard record.state != .cancelled else { throw AgentRecoveryError.cancelled }
        try store.stopLifecycle(handle, state: .suspended)
        logger.recovery("operation.suspended", record: record)
    }

    /// Terminal for this handle, including active executions. Cancellation cannot undo a host commit already made.
    public func cancelStructuredRecovery(_ handle: AgentStructuredRecoveryHandle,
        store: AgentStructuredRecoveryStore) async throws {
        let record = try store.load(handle)
        _ = try await recoverySession(for: record)
        try store.stopLifecycle(handle, state: .cancelled)
        // Active owners observe the command and persist their own terminal state.
        if let lease = try? store.acquire(handle) {
            defer { withExtendedLifetime(lease) {} }
            var cancelled = try store.load(handle)
            cancelled.state = .cancelled
            cancelled.completedPayload = nil
            try store.save(cancelled)
        }
        logger.recovery("operation.cancelled", record: record)
    }

    /// Idempotent after the host has durably committed. Deletes content, retaining a small disposition marker.
    public func acknowledgeStructuredRecovery(_ handle: AgentStructuredRecoveryHandle,
        store: AgentStructuredRecoveryStore) async throws {
        let lease = try store.acquire(handle)
        defer { withExtendedLifetime(lease) {} }
        if let disposition = try store.disposition(handle) {
            let session = try await sessionManager.requireSession()
            guard session.binding == disposition.binding else { throw ChatGPTSessionError.accountChanged }
            guard disposition.state == .acknowledged else { throw AgentRecoveryError.completionUnavailable }
            try store.remove(handle)
            return
        }
        let record = try store.load(handle)
        _ = try await recoverySession(for: record)
        guard record.state == .completed, try store.lifecycle(handle)?.state != .cancelled else {
            throw AgentRecoveryError.completionUnavailable
        }
        try store.dispose(record, state: .acknowledged)
        logger.recovery("receipt.acknowledged", record: record)
    }

    /// The host decided this result is no longer applicable. Cancel and await any active send first.
    public func abandonStructuredRecovery(_ handle: AgentStructuredRecoveryHandle,
        store: AgentStructuredRecoveryStore) async throws {
        let lease = try store.acquire(handle)
        defer { withExtendedLifetime(lease) {} }
        if let disposition = try store.disposition(handle) {
            let session = try await sessionManager.requireSession()
            guard session.binding == disposition.binding else { throw ChatGPTSessionError.accountChanged }
            try store.remove(handle)
            return
        }
        let record = try store.load(handle)
        _ = try await recoverySession(for: record)
        try store.stopLifecycle(handle, state: .cancelled)
        try store.dispose(record, state: .abandoned)
        logger.recovery("operation.abandoned", record: record)
    }

    /// Enumerates independent jobs for the current account. Corrupt/unknown records are reported separately.
    public func structuredRecoveries(store: AgentStructuredRecoveryStore,
        scope: String? = nil) async throws -> AgentRecoveryInventory {
        let session = try await sessionManager.requireSession()
        var statuses: [AgentStructuredRecoveryStatus] = []
        var unreadable: [UUID] = []
        for handle in try store.handles() {
            do {
                if let marker = try store.disposition(handle) {
                    if marker.binding == session.binding, scope == nil || marker.scope == scope { statuses.append(marker.status) }
                } else {
                    let record = try store.load(handle)
                    if record.binding == session.binding, scope == nil || record.scope == scope {
                        statuses.append(try await structuredRecoveryStatus(handle, store: store))
                    }
                }
            } catch { unreadable.append(handle.id) }
        }
        try await validateActiveAuthentication(session)
        return .init(operations: statuses, unreadableRecordIDs: unreadable)
    }
}

public struct AgentRecoveryInventory: Sendable {
    public let operations: [AgentStructuredRecoveryStatus]
    /// Their account/scope cannot be established safely. They were not deleted or regenerated.
    public let unreadableRecordIDs: [UUID]
}
