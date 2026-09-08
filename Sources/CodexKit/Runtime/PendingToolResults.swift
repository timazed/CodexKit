import Foundation

/// Retains at most one result per announced call, including results submitted
/// out of order before the runner begins waiting for that call.
actor PendingToolResults {
    private struct Entry {
        let toolName: String
        var result: ToolResultEnvelope?
        var waiter: (id: UUID, continuation: CheckedContinuation<ToolResultEnvelope, Error>)?
    }

    private var entries: [String: Entry] = [:]
    private var closed = false

    func register(_ invocations: [ToolInvocation]) throws {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        guard Set(invocations.map(\.id)).count == invocations.count,
              invocations.allSatisfy({ entries[$0.id] == nil }) else {
            throw AgentRuntimeError(code: "duplicate_tool_call", message: "Response contains duplicate pending tool call IDs.")
        }
        for invocation in invocations { entries[invocation.id] = Entry(toolName: invocation.toolName) }
    }

    func wait(for id: String) async throws -> ToolResultEnvelope {
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            guard !closed else { throw CancellationError() }
            guard var entry = entries[id], entry.waiter == nil else {
                throw invalidResult("The tool call is not pending or already has a waiter.")
            }
            if let result = entry.result {
                entries[id] = nil
                return result
            }
            let result = try await withCheckedThrowingContinuation { continuation in
                entry.waiter = (waiterID, continuation)
                entries[id] = entry
            }
            try Task.checkCancellation()
            return result
        } onCancel: {
            Task { await self.cancelWaiter(waiterID, for: id) }
        }
    }

    func resolve(_ result: ToolResultEnvelope, for id: String) throws {
        try Task.checkCancellation()
        guard !closed, var entry = entries[id] else {
            throw invalidResult("No pending tool call accepts this result.")
        }
        guard result.invocationID == id, result.toolName == entry.toolName else {
            throw invalidResult("The result must identify the requested invocation and tool.")
        }
        guard entry.result == nil else {
            throw invalidResult("A result has already been submitted for this tool call.")
        }
        if let waiter = entry.waiter {
            entries[id] = nil
            waiter.continuation.resume(returning: result)
        } else {
            entry.result = result
            entries[id] = entry
        }
    }

    func close() {
        closed = true
        let pending = entries
        entries.removeAll()
        for entry in pending.values { entry.waiter?.continuation.resume(throwing: CancellationError()) }
    }

    private func cancelWaiter(_ waiterID: UUID, for id: String) {
        guard let entry = entries[id], entry.waiter?.id == waiterID else { return }
        entries[id] = nil
        entry.waiter?.continuation.resume(throwing: CancellationError())
    }

    private func invalidResult(_ message: String) -> AgentRuntimeError {
        .init(code: "invalid_tool_result", message: message)
    }
}
