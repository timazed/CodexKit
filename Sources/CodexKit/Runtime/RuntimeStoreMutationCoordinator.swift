import Foundation

package enum RuntimeStoreMutationCoordinatorError: Error, Equatable {
    case exclusiveLeaseExpansionUnsupported
}

/// Serializes state mutations that span a database transaction and its
/// attachment sidecar. Database engines serialize their own writes, but they
/// cannot also protect the filesystem work performed immediately before and
/// after those writes.
package actor RuntimeStoreMutationCoordinator {
    package static let shared = RuntimeStoreMutationCoordinator()

    @TaskLocal private static var exclusivelyHeldStoreKeys: Set<String> = []

    private struct PendingMutation {
        let id: UUID
        let completion: RuntimeStoreTask<Void>
    }

    private var pendingByStore: [String: PendingMutation] = [:]

    package func perform<Result: Sendable>(
        for attachmentRootURL: URL,
        operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        try Task.checkCancellation()
        let canonicalRootURL = RuntimeStoreInterprocessLock.canonicalRootURL(
            for: attachmentRootURL
        )
        let key = canonicalRootURL.path
        if Self.exclusivelyHeldStoreKeys.contains(key) {
            return try await operation()
        }
        let predecessor = pendingByStore[key]?.completion
        let operationTask = RuntimeStoreTask<Result> {
            _ = try await predecessor?.value
            let lock = try await RuntimeStoreInterprocessLock.acquire(
                for: canonicalRootURL
            )
            defer { lock.release() }
            try RuntimeStoreCommitScope.begin()
            return try await operation()
        }
        let mutationID = UUID()
        let completion = RuntimeStoreTask<Void>(preservingCommits: false, inheritingCommitScope: false) {
            _ = try? await predecessor?.uninterruptibleValue
            _ = try? await operationTask.uninterruptibleValue
            await self.removePendingMutation(key: key, id: mutationID)
        }
        pendingByStore[key] = PendingMutation(
            id: mutationID,
            completion: completion
        )
        return try await withTaskCancellationHandler {
            try await operationTask.uninterruptibleValue
        } onCancel: { operationTask.cancel() }
    }

    package func performExclusively<Result: Sendable>(
        for attachmentRootURLs: [URL],
        operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        try Task.checkCancellation()
        let rootsByKey = Dictionary(
            attachmentRootURLs.map {
                let canonical = RuntimeStoreInterprocessLock.canonicalRootURL(for: $0)
                return (canonical.path, canonical)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let requestedKeys = rootsByKey.keys.sorted()
        guard !requestedKeys.isEmpty else { return try await operation() }
        let requestedKeySet = Set(requestedKeys)
        let heldKeys = Self.exclusivelyHeldStoreKeys
        if requestedKeySet.isSubset(of: heldKeys) {
            return try await operation()
        }
        guard requestedKeySet.isDisjoint(with: heldKeys) else {
            throw RuntimeStoreMutationCoordinatorError.exclusiveLeaseExpansionUnsupported
        }
        let keys = requestedKeys

        let predecessors = keys.compactMap { pendingByStore[$0]?.completion }
        let operationTask = RuntimeStoreTask<Result> {
            for predecessor in predecessors { try await predecessor.value }
            let uniqueLockRoots = Dictionary(
                keys.compactMap { rootsByKey[$0] }.map {
                    (RuntimeStoreInterprocessLock.lockURL(for: $0).path, $0)
                },
                uniquingKeysWith: { first, _ in first }
            )
            var locks: [RuntimeStoreInterprocessLock] = []
            for lockKey in uniqueLockRoots.keys.sorted() {
                guard let root = uniqueLockRoots[lockKey] else { continue }
                do {
                    locks.append(try await RuntimeStoreInterprocessLock.acquire(for: root))
                } catch {
                    locks.reversed().forEach { $0.release() }
                    throw error
                }
            }
            defer { locks.reversed().forEach { $0.release() } }
            try RuntimeStoreCommitScope.begin()
            return try await Self.$exclusivelyHeldStoreKeys.withValue(
                Self.exclusivelyHeldStoreKeys.union(requestedKeySet)
            ) {
                try await operation()
            }
        }
        let mutationID = UUID()
        let completion = RuntimeStoreTask<Void>(preservingCommits: false, inheritingCommitScope: false) {
            for predecessor in predecessors { _ = try? await predecessor.uninterruptibleValue }
            _ = try? await operationTask.uninterruptibleValue
            for key in keys { await self.removePendingMutation(key: key, id: mutationID) }
        }
        for key in keys {
            pendingByStore[key] = PendingMutation(id: mutationID, completion: completion)
        }

        return try await withTaskCancellationHandler {
            try await operationTask.uninterruptibleValue
        } onCancel: { operationTask.cancel() }
    }

    private func removePendingMutation(key: String, id: UUID) {
        guard pendingByStore[key]?.id == id else { return }
        pendingByStore[key] = nil
    }
}
