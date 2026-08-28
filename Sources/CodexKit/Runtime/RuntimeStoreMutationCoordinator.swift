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
        let completion: Task<Void, Never>
    }

    private var pendingByStore: [String: PendingMutation] = [:]

    package func perform<Result: Sendable>(
        for attachmentRootURL: URL,
        operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        let canonicalRootURL = RuntimeStoreInterprocessLock.canonicalRootURL(
            for: attachmentRootURL
        )
        let key = canonicalRootURL.path
        if Self.exclusivelyHeldStoreKeys.contains(key) {
            return try await operation()
        }
        let predecessor = pendingByStore[key]?.completion
        let operationTask = Task<Result, Error> {
            await predecessor?.value
            let lock = try await RuntimeStoreInterprocessLock.acquire(
                for: canonicalRootURL
            )
            defer { lock.release() }
            return try await operation()
        }
        let mutationID = UUID()
        pendingByStore[key] = PendingMutation(
            id: mutationID,
            completion: Task { _ = try? await operationTask.value }
        )

        do {
            let result = try await operationTask.value
            removePendingMutation(key: key, id: mutationID)
            return result
        } catch {
            removePendingMutation(key: key, id: mutationID)
            throw error
        }
    }

    package func performExclusively<Result: Sendable>(
        for attachmentRootURLs: [URL],
        operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
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
        let operationTask = Task<Result, Error> {
            for predecessor in predecessors { await predecessor.value }
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
            return try await Self.$exclusivelyHeldStoreKeys.withValue(
                Self.exclusivelyHeldStoreKeys.union(requestedKeySet)
            ) {
                try await operation()
            }
        }
        let mutationID = UUID()
        let completion = Task { _ = try? await operationTask.value }
        for key in keys {
            pendingByStore[key] = PendingMutation(id: mutationID, completion: completion)
        }

        do {
            let result = try await operationTask.value
            for key in keys { removePendingMutation(key: key, id: mutationID) }
            return result
        } catch {
            for key in keys { removePendingMutation(key: key, id: mutationID) }
            throw error
        }
    }

    private func removePendingMutation(key: String, id: UUID) {
        guard pendingByStore[key]?.id == id else { return }
        pendingByStore[key] = nil
    }
}
