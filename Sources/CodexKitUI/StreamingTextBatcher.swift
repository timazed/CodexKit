import Foundation

/// Coalesces presentation updates without delaying consumption of runtime events.
@MainActor
final class StreamingTextBatcher {
    private var pending = ""
    private var publish: (@MainActor (String) -> Void)?
    private var task: Task<Void, Never>?
    private let interval: Duration

    init(interval: Duration = .milliseconds(33)) {
        self.interval = interval
    }

    func append(_ delta: String, publish: @escaping @MainActor (String) -> Void) {
        guard !delta.isEmpty else { return }
        pending.append(delta)
        self.publish = publish
        guard task == nil else { return }
        let interval = interval
        task = Task { [weak self] in
            do { try await Task.sleep(for: interval) }
            catch { return }
            self?.flush()
        }
    }

    func flush() {
        let text = pending
        let callback = publish
        reset()
        if !text.isEmpty { callback?(text) }
    }

    func reset() {
        task?.cancel()
        task = nil
        pending = ""
        publish = nil
    }

    deinit { task?.cancel() }
}
