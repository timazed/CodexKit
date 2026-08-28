import Foundation

/// A finite host-provided execution allowance held while an agent turn is active.
public protocol AgentBackgroundActivity: Sendable {
    /// Releases the allowance. Implementations must make repeated calls harmless.
    func end()
}

/// Lets a host keep an active turn running for the limited time its platform allows.
public protocol AgentBackgroundActivityProviding: Sendable {
    func beginActivity(
        named name: String,
        expirationHandler: @escaping @Sendable () -> Void
    ) async -> any AgentBackgroundActivity
}

/// The default provider, which does not request additional execution time.
public struct NoOpAgentBackgroundActivityProvider: AgentBackgroundActivityProviding {
    public init() {}

    public func beginActivity(
        named _: String,
        expirationHandler _: @escaping @Sendable () -> Void
    ) async -> any AgentBackgroundActivity {
        NoOpAgentBackgroundActivity()
    }
}

private struct NoOpAgentBackgroundActivity: AgentBackgroundActivity {
    func end() {}
}

final class AgentTurnCancellationHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellationAction: (@Sendable () -> Void)?
    private var cancellationRequested = false

    func install(_ action: @escaping @Sendable () -> Void) {
        lock.lock()
        if cancellationRequested {
            lock.unlock()
            action()
            return
        }
        cancellationAction = action
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancellationRequested = true
        let action = cancellationAction
        lock.unlock()
        action?()
    }

    func clear() {
        lock.lock()
        cancellationAction = nil
        lock.unlock()
    }
}
