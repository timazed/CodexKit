import Foundation

/// Serializes steering acceptance with the final completion decision.
actor CodexTurnControl {
    private var queued: [AgentMessage] = []
    private var closed = false
    private var outputBegan = false

    func steer(_ message: AgentMessage) throws {
        try Task.checkCancellation()
        guard !outputBegan else { throw AgentOutputError.protocolViolation("Steering is unavailable after final output begins.") }
        guard !closed else {
            throw AgentRuntimeError(code: .turnNotActive, message: "The turn has already ended.")
        }
        guard queued.count < AgentStoreLimits.maximumPendingSteeringMessageCount else {
            throw AgentRuntimeError(code: .steeringQueueFull, message: "The turn's pending input queue is full. Wait for the next model pass before adding more input.")
        }
        queued.append(message)
    }

    func drain(closeIfEmpty: Bool) -> [AgentMessage] {
        if queued.isEmpty && closeIfEmpty { closed = true }
        defer { queued.removeAll() }
        return queued
    }

    func close() { closed = true; queued.removeAll() }

    func beginOutput() throws {
        guard queued.isEmpty else { throw AgentOutputError.protocolViolation("Final output began before queued steering was consumed.") }
        outputBegan = true
    }
}
