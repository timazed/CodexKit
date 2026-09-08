import Foundation

/// Shared across model passes and retries so queued deltas, provider items,
/// and incomplete tool batches cannot grow for an entire turn unchecked.
final class CodexResponseBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int?
    private var remainingItems = AgentStoreLimits.maximumResponseItemCount

    init(maximumBytes: Int?) { remaining = maximumBytes.map { max(0, $0) } }

    func consumeItem() throws {
        try lock.withLock {
            guard remainingItems > 0 else { throw AgentRuntimeError.executionLimitExceeded(.responseItems) }
            remainingItems -= 1
        }
    }

    func consume(_ count: Int) throws {
        try lock.withLock {
            guard let remaining else { return }
            guard count <= remaining else { throw AgentRuntimeError.executionLimitExceeded(.responseBytes) }
            self.remaining = remaining - count
        }
    }
}
