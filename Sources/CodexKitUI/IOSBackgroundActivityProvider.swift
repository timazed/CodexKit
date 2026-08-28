#if canImport(UIKit)
import CodexKit
import UIKit

/// Uses an iOS background task to give an active agent turn a short completion window.
///
/// This does not make a turn durable. iOS still decides how much additional time is
/// available, and the turn is cancelled when that allowance expires.
public struct IOSBackgroundActivityProvider: AgentBackgroundActivityProviding {
    public init() {}

    public func beginActivity(
        named name: String,
        expirationHandler: @escaping @Sendable () -> Void
    ) async -> any AgentBackgroundActivity {
        let activity = await MainActor.run { IOSBackgroundActivity() }
        await activity.begin(named: name, expirationHandler: expirationHandler)
        return activity
    }
}

@MainActor
private final class IOSBackgroundActivity: AgentBackgroundActivity, @unchecked Sendable {
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    private var hasEnded = false

    func begin(
        named name: String,
        expirationHandler: @escaping @Sendable () -> Void
    ) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            expirationHandler()
            self?.endOnMainActor()
        }
    }

    nonisolated func end() {
        Task { @MainActor [weak self] in
            self?.endOnMainActor()
        }
    }

    private func endOnMainActor() {
        guard !hasEnded else { return }
        hasEnded = true
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
#endif
