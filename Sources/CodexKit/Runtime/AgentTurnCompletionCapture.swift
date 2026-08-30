actor AgentTurnCompletionCapture {
    private var recordedMemoryApplication: MemoryApplicationOutcome?

    func record(memoryApplication: MemoryApplicationOutcome) {
        guard recordedMemoryApplication == nil else { return }
        recordedMemoryApplication = memoryApplication
    }

    func memoryApplication() -> MemoryApplicationOutcome {
        recordedMemoryApplication ?? .notApplied(.notReported)
    }
}
