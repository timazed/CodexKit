import Foundation

actor AgentRuntimePersistenceCoordinator {
    private let store: any RuntimeStateStoring
    private var tail: RuntimeStoreTask<Void>?

    init(store: any RuntimeStateStoring) {
        self.store = store
    }

    func apply(_ operations: [AgentStoreWriteOperation]) async throws {
        try Task.checkCancellation()
        guard !operations.isEmpty else { return }

        let predecessor = tail
        let store = store
        let operation = RuntimeStoreTask<Void> {
            if let predecessor {
                try await predecessor.value
            }
            try Task.checkCancellation()
            // Built-in disk stores announce the commit after acquiring their
            // lease. For custom stores, conservatively protect the whole call.
            if !(store is any StoreMigrationCoordinating) { try RuntimeStoreCommitScope.begin() }
            try await store.apply(operations)
        }
        tail = RuntimeStoreTask<Void>(preservingCommits: false, inheritingCommitScope: false) {
            _ = try? await predecessor?.uninterruptibleValue
            _ = try? await operation.uninterruptibleValue
        }
        try await withTaskCancellationHandler {
            try await operation.uninterruptibleValue
        } onCancel: { operation.cancel() }
    }

    func loadThreadActivationState(
        id: String,
        policy: AgentThreadActivationPolicy
    ) async throws -> AgentThreadActivationState {
        try Task.checkCancellation()
        let predecessor = tail
        let store = store
        let operation = RuntimeStoreTask<AgentThreadActivationState>(preservingCommits: false) {
            if let predecessor {
                try await predecessor.value
            }
            try Task.checkCancellation()
            return try await store.loadThreadActivationState(id: id, policy: policy)
        }
        tail = RuntimeStoreTask<Void>(preservingCommits: false, inheritingCommitScope: false) {
            _ = try? await predecessor?.uninterruptibleValue
            _ = try? await operation.uninterruptibleValue
        }
        return try await withTaskCancellationHandler {
            try await operation.uninterruptibleValue
        } onCancel: { operation.cancel() }
    }
}
