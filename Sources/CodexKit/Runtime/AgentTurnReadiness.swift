import Foundation

/// One-shot startup result. The transport resolves this before publishing any
/// response content, so startup recovery cannot replay committed tool effects.
actor AgentTurnReadiness {
    private var result: Result<Void, Error>?
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    func wait() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if let result { return try result.get() }
            try await withCheckedThrowingContinuation { waiters[id] = $0 }
            try Task.checkCancellation()
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    func resolve(_ result: Result<Void, Error>) {
        guard self.result == nil else { return }
        self.result = result
        let pending = waiters
        waiters.removeAll()
        pending.values.forEach { $0.resume(with: result) }
    }

    private func cancelWaiter(_ id: UUID) { waiters.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
}
