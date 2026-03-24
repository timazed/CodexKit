import Foundation

public actor InMemoryRuntimeStateStore: RuntimeStateStoring, RuntimeStateInspecting, AgentRuntimeQueryableStore {
    private var state: StoredRuntimeState
    private let logger: AgentLogger

    public init(
        initialState: StoredRuntimeState = .empty,
        logging: AgentLoggingConfiguration = .disabled
    ) {
        state = initialState.normalized()
        logger = AgentLogger(configuration: logging)
    }

    public func loadState() async throws -> StoredRuntimeState {
        logger.debug(.persistence, "Loading in-memory runtime state.")
        return state
    }

    public func saveState(_ state: StoredRuntimeState) async throws {
        logger.debug(
            .persistence,
            "Saving in-memory runtime state.",
            metadata: ["threads": "\(state.threads.count)"]
        )
        self.state = state.normalized()
    }

    public func prepare() async throws -> AgentStoreMetadata {
        logger.info(.persistence, "Preparing in-memory runtime state store.")
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
