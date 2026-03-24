import Foundation

public actor InMemoryRuntimeStateStore: RuntimeStateStoring, RuntimeStateInspecting, AgentRuntimeQueryableStore {
    private var state: StoredRuntimeState

    public init(initialState: StoredRuntimeState = .empty) {
        state = initialState.normalized()
    }

    public func loadState() async throws -> StoredRuntimeState {
        state
    }

    public func saveState(_ state: StoredRuntimeState) async throws {
        self.state = state.normalized()
    }

    public func prepare() async throws -> AgentStoreMetadata {
        state = state.normalized()
        return try await readMetadata()
    }

    public func readMetadata() async throws -> AgentStoreMetadata {
        AgentStoreMetadata(
            logicalSchemaVersion: .v1,
            storeSchemaVersion: 1,
            capabilities: AgentStoreCapabilities(
                supportsPushdownQueries: true,
                supportsCrossThreadQueries: true,
                supportsSorting: true,
                supportsFiltering: true,
                supportsMigrations: false
            ),
            storeKind: "InMemoryRuntimeStateStore"
        )
    }

    public func fetchThreadSummary(id: String) async throws -> AgentThreadSummary {
        try state.threadSummary(id: id)
    }

    public func fetchThreadHistory(
        id: String,
        query: AgentHistoryQuery
    ) async throws -> AgentThreadHistoryPage {
        try state.threadHistoryPage(id: id, query: query)
    }

    public func fetchLatestStructuredOutputMetadata(id: String) async throws -> AgentStructuredOutputMetadata? {
        try state.threadSummary(id: id).latestStructuredOutputMetadata
    }

    public func fetchThreadContextState(id: String) async throws -> AgentThreadContextState? {
        state.contextStateByThread[id]
    }
}
