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
}
