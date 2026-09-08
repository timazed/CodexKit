import Foundation

/// A single runtime execution, including ephemeral work. Its ID exists before
/// backend startup and is distinct from the provider's eventual turn ID.
public struct AgentExecution<Event: Sendable>: Sendable {
    public let id: UUID
    public let threadID: String
    public let events: AsyncThrowingStream<Event, Error>
    private let control: AgentExecutionControl

    init(events: AsyncThrowingStream<Event, Error>, control: AgentExecutionControl) {
        id = control.id
        threadID = control.threadID
        self.events = events
        self.control = control
    }

    /// Waits for initial backend acceptance, independently of event consumption.
    /// Cancelling this wait does not cancel the execution or other waiters.
    public func waitUntilReady() async throws { try await control.readiness.wait() }

    /// Requests cooperative cancellation of this exact execution.
    public func cancel() { control.cancellation.cancel() }

    /// Queues input on this execution only. Fails before readiness or after completion.
    public func steer(_ text: String, images: [AgentImageAttachment] = []) async throws {
        try await control.steer(text, images: images)
    }
}

final class AgentExecutionControl: @unchecked Sendable {
    let id: UUID
    let threadID: String
    let cancellation: AgentTurnCancellationHandle
    let readiness = AgentTurnReadiness()
    private let lock = NSLock()
    private var backend: AgentTurnStream?
    private var finished = false

    init(threadID: String, execution: AgentActiveTurnExecution?) {
        id = execution?.id ?? UUID()
        self.threadID = threadID
        cancellation = execution?.cancellation ?? AgentTurnCancellationHandle()
    }

    func install(_ stream: AgentTurnStream) { lock.withLock { backend = stream } }

    /// Cleanup also owns streams accepted before initial runtime events drain.
    /// Invoke backend code outside the lock, and release ownership only once.
    func finish() {
        let stream = lock.withLock {
            finished = true
            defer { backend = nil }
            return backend
        }
        stream?.interrupt()
    }

    func steer(_ text: String, images: [AgentImageAttachment]) async throws {
        try Task.checkCancellation()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty else {
            throw AgentRuntimeError.invalidMessageContent()
        }
        let stream = try lock.withLock {
            guard !finished else { throw AgentRuntimeError(code: "turn_not_active", message: "This execution has ended.") }
            guard let backend else { throw AgentRuntimeError(code: "execution_not_ready", message: "Wait for this execution to become ready before steering.") }
            return backend
        }
        try await stream.steer(.init(threadID: threadID, role: .user, text: text, images: images))
    }
}
