import Foundation

/// Serializes steering acceptance with the final completion decision.
actor CodexTurnControl {
    private var queued: [AgentMessage] = []
    private var closed = false

    func steer(_ message: AgentMessage) throws {
        try Task.checkCancellation()
        guard !closed else {
            throw AgentRuntimeError(code: "turn_not_active", message: "The turn has already ended.")
        }
        queued.append(message)
    }

    func drain(closeIfEmpty: Bool) -> [AgentMessage] {
        if queued.isEmpty && closeIfEmpty { closed = true }
        defer { queued.removeAll() }
        return queued
    }

    func close() { closed = true; queued.removeAll() }
}

/// Cancellation must release continuations even while no model events arrive.
struct PendingToolResults: Sendable {
    private actor Storage {
        private var waiting: [String: CheckedContinuation<ToolResultEnvelope, Error>] = [:]
        private var resolved: [String: ToolResultEnvelope] = [:]
        private var cancelled: Set<String> = []

        func wait(for id: String) async throws -> ToolResultEnvelope {
            try Task.checkCancellation()
            if cancelled.remove(id) != nil { throw CancellationError() }
            if let result = resolved.removeValue(forKey: id) { return result }
            return try await withCheckedThrowingContinuation { continuation in
                waiting[id] = continuation
            }
        }
        func cancel(_ id: String) {
            if let continuation = waiting.removeValue(forKey: id) {
                continuation.resume(throwing: CancellationError())
            } else { cancelled.insert(id) }
            resolved[id] = nil
        }
        func resolve(_ result: ToolResultEnvelope, for id: String) {
            guard !cancelled.contains(id) else { return }
            if let continuation = waiting.removeValue(forKey: id) { continuation.resume(returning: result) }
            else { resolved[id] = result }
        }
    }
    private let storage = Storage()
    func wait(for id: String) async throws -> ToolResultEnvelope {
        try await withTaskCancellationHandler {
            try await storage.wait(for: id)
        } onCancel: {
            Task { await storage.cancel(id) }
        }
    }
    func resolve(_ result: ToolResultEnvelope, for id: String) async {
        await storage.resolve(result, for: id)
    }
}
