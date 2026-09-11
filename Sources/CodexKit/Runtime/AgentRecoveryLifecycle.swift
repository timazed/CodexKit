import Foundation

struct RecoveryLifecycleRecord: Codable, Sendable {
    enum State: String, Codable, Sendable { case active, suspended, cancelled }
    let runID: UUID
    var state: State
}

/// A separate, brief lock serializes stop commands against accepting a completion or transmission.
/// The execution lease remains exclusively owned while a transport or host callback is outstanding.
struct AgentRecoveryLifecycle: Sendable {
    let store: AgentStructuredRecoveryStore
    let handle: AgentStructuredRecoveryHandle
    let runID: UUID

    func check() throws {
        try Task.checkCancellation()
        guard let current = try store.lifecycle(handle), current.runID == runID,
              current.state == .active else { throw CancellationError() }
    }
    func performWhileActive<T>(_ body: () throws -> T) throws -> T {
        let lease = try store.acquireLock(handle.id.uuidString + ".control.lock", waiting: true)
        defer { withExtendedLifetime(lease) {} }
        try check()
        return try body()
    }
    func suspend() {
        try? store.stopLifecycle(handle, state: .suspended, expectedRunID: runID)
    }
}

extension AgentStructuredRecoveryStore {
    func lifecycle(_ handle: AgentStructuredRecoveryHandle) throws -> RecoveryLifecycleRecord? {
        let path = url(handle, suffix: ".control.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        return try JSONDecoder().decode(RecoveryLifecycleRecord.self, from: readData(path))
    }
    func beginLifecycle(_ handle: AgentStructuredRecoveryHandle) throws -> AgentRecoveryLifecycle {
        let lease = try acquireLock(handle.id.uuidString + ".control.lock", waiting: true)
        defer { withExtendedLifetime(lease) {} }
        if try lifecycle(handle)?.state == .cancelled { throw AgentRecoveryError.cancelled }
        let command = RecoveryLifecycleRecord(runID: UUID(), state: .active)
        try write(JSONEncoder().encode(command), to: url(handle, suffix: ".control.json"))
        return .init(store: self, handle: handle, runID: command.runID)
    }
    func stopLifecycle(_ handle: AgentStructuredRecoveryHandle, state: RecoveryLifecycleRecord.State,
                       expectedRunID: UUID? = nil) throws {
        let lease = try acquireLock(handle.id.uuidString + ".control.lock", waiting: true)
        defer { withExtendedLifetime(lease) {} }
        let previous = try lifecycle(handle)
        if let expectedRunID, previous?.runID != expectedRunID { return }
        if previous?.state == .cancelled { return }
        let command = RecoveryLifecycleRecord(runID: previous?.runID ?? UUID(), state: state)
        try write(JSONEncoder().encode(command), to: url(handle, suffix: ".control.json"))
    }
}
