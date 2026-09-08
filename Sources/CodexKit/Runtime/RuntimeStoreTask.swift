import Foundation

/// Storage work owns its result independently of individual waiters. Cancellation
/// can withdraw queued work, but cannot interrupt a database/attachment commit.
package final class RuntimeStoreTask<Value: Sendable>: Sendable {
    private let task: Task<Value, Error>
    private let completion: RuntimeStoreTaskCompletion<Value>

    package init(
        preservingCommits: Bool = true,
        inheritingCommitScope: Bool = true,
        operation: @escaping @Sendable () async throws -> Value
    ) {
        let completion = RuntimeStoreTaskCompletion<Value>()
        self.completion = completion
        task = Task {
            let observers = inheritingCommitScope ? RuntimeStoreCommitScope.observers : []
            let result: Result<Value, Error>
            do {
                let value = try await RuntimeStoreCommitScope.$observers.withValue(
                    preservingCommits ? observers + [completion] : observers
                ) { try await operation() }
                result = .success(value)
            } catch { result = .failure(error) }
            completion.resolve(result)
            return try result.get()
        }
    }

    /// Cancels only this wait before a commit begins; shared work keeps running.
    package var value: Value { get async throws { try await completion.wait() } }

    /// Queue barriers and owners must observe actual completion, even when their
    /// caller is cancelled. Otherwise a successor could overtake an earlier write.
    package var uninterruptibleValue: Value { get async throws { try await task.value } }

    /// Withdraws the operation before its commit boundary, including lock waits.
    package func cancel() {
        if completion.cancelOperation() { task.cancel() }
    }
}

private protocol RuntimeStoreCommitObserving: Sendable {
    func beginCommit() throws
}

package enum RuntimeStoreCommitScope {
    @TaskLocal fileprivate static var observers: [any RuntimeStoreCommitObserving] = []

    /// Called after all leases are held, before any filesystem/database mutation.
    package static func begin() throws {
        try Task.checkCancellation()
        for observer in observers { try observer.beginCommit() }
    }
}

private final class RuntimeStoreTaskCompletion<Value: Sendable>: RuntimeStoreCommitObserving, @unchecked Sendable {
    private enum Phase { case waiting, cancelled, committing }
    private let lock = NSLock()
    private var phase = Phase.waiting
    private var result: Result<Value, Error>?
    private var waiters: [UUID: CheckedContinuation<Value, Error>] = [:]

    func beginCommit() throws {
        try lock.withLock {
            guard phase != .cancelled else { throw CancellationError() }
            phase = .committing
        }
    }

    func cancelOperation() -> Bool {
        lock.withLock {
            guard phase == .waiting, result == nil else { return false }
            phase = .cancelled
            return true
        }
    }

    func wait() async throws -> Value {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let ready: Result<Value, Error>? = lock.withLock {
                    if let result { return result }
                    if Task.isCancelled, phase != .committing { return .failure(CancellationError()) }
                    waiters[id] = continuation
                    return nil
                }
                if let ready { continuation.resume(with: ready) }
            }
        } onCancel: { self.cancelWaiter(id) }
    }

    private func cancelWaiter(_ id: UUID) {
        let continuation = lock.withLock {
            phase == .committing ? nil : waiters.removeValue(forKey: id)
        }
        continuation?.resume(throwing: CancellationError())
    }

    func resolve(_ result: Result<Value, Error>) {
        let pending = lock.withLock {
            self.result = result
            defer { waiters.removeAll() }
            return Array(waiters.values)
        }
        pending.forEach { $0.resume(with: result) }
    }
}
