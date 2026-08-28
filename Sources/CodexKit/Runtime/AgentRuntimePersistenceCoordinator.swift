import Foundation

actor AgentRuntimePersistenceCoordinator {
    private let store: any RuntimeStateStoring
    private var tail: Task<Void, Never>?

    init(store: any RuntimeStateStoring) {
        self.store = store
    }

    func apply(_ operations: [AgentStoreWriteOperation]) async throws {
        guard !operations.isEmpty else { return }

        let predecessor = tail
        let store = store
        let operation = Task<Void, Error> {
            if let predecessor {
                await predecessor.value
            }
            try await store.apply(operations)
        }
        tail = Task {
            _ = try? await operation.value
        }
        try await operation.value
    }

    func loadThreadActivationState(
        id: String,
        policy: AgentThreadActivationPolicy
    ) async throws -> AgentThreadActivationState {
        let predecessor = tail
        let store = store
        let operation = Task<AgentThreadActivationState, Error> {
            if let predecessor {
                await predecessor.value
            }
            return try await store.loadThreadActivationState(id: id, policy: policy)
        }
        tail = Task {
            _ = try? await operation.value
        }
        return try await operation.value
    }
}
