import Foundation

extension AgentRuntime {
    /// Held across suspension points by operations that replace or extend context.
    func reserveThreadOperation(in threadID: String) throws -> UUID {
        try Task.checkCancellation()
        guard !isRestoring else {
            throw AgentRuntimeError(code: .runtimeBusy, message: "Wait for runtime restoration to finish.")
        }
        guard threadOperations[threadID] == nil else {
            throw AgentRuntimeError(code: .threadBusy, message: "This thread already has an active turn, compaction, or resume operation.")
        }
        let id = UUID()
        threadOperations[threadID] = id
        return id
    }

    func releaseThreadOperation(in threadID: String, id: UUID) {
        guard threadOperations[threadID] == id else { return }
        threadOperations[threadID] = nil
        if deferredThreadDeactivations.remove(threadID) != nil { deactivateThread(id: threadID) }
    }
}
