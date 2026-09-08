import Foundation

struct AgentRuntimePendingStoreOperation: Sendable {
    let generation: UInt64
    let operation: AgentStoreWriteOperation

    var affectedThreadID: String {
        operation.affectedThreadID
    }
}

struct AgentRuntimeActivePersistenceTask: Sendable {
    let id: UInt64
    let firstGeneration: UInt64
    let lastGeneration: UInt64
    let task: RuntimeStoreTask<Void>
}

struct AgentRuntimePersistenceBatch: Sendable {
    let orderedThreadIDs: [String]
    let operationsByThread: [String: [AgentStoreWriteOperation]]
    let observationSnapshots: [String: AgentRuntimeObservationBatchSnapshot]
}

extension AgentRuntime {
    func persistState(waitDespiteCancellation: Bool = false) async throws {
        guard let requestedGeneration = pendingStoreOperations.last?.generation ?? activePersistenceTask?.lastGeneration else {
            return
        }

        while true {
            if let active = activePersistenceTask {
                if active.firstGeneration > requestedGeneration { return }
                do {
                    if waitDespiteCancellation { try await active.task.uninterruptibleValue }
                    else { try await active.task.value }
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                    clearActivePersistenceTask(id: active.id)
                    if hasUnfinishedPersistence(through: requestedGeneration) {
                        continue
                    }
                    throw error
                }
                clearActivePersistenceTask(id: active.id)
                if hasUnfinishedPersistence(through: requestedGeneration) {
                    continue
                }
                return
            }

            guard pendingStoreOperations.contains(where: {
                $0.generation <= requestedGeneration
            }) else {
                return
            }
            guard pendingStoreOperations.count
                <= AgentStoreLimits.maximumPendingWriteOperationCount else {
                throw AgentStoreError.invalidInput(
                    "pending runtime writes exceed their bounded limit"
                )
            }

            let queued = pendingStoreOperations
            let operations = coalescedStoreOperations(queued.map(\.operation))
            try AgentStoreLimitValidator.validate(operations)
            pendingStoreOperations.removeAll(keepingCapacity: true)
            logger.debug(
                .persistence,
                "Applying incremental runtime store operations.",
                metadata: [
                    "count": "\(operations.count)",
                    "original_count": "\(queued.count)",
                ]
            )

            let batch = makePersistenceBatch(operations)
            nextPersistenceTaskID &+= 1
            let taskID = nextPersistenceTaskID
            let task = RuntimeStoreTask<Void>(inheritingCommitScope: false) {
                do {
                    try await self.applyPersistenceBatch(batch)
                    await self.finishPersistenceTask(id: taskID)
                } catch {
                    await self.finishPersistenceTask(id: taskID)
                    throw error
                }
            }
            activePersistenceTask = AgentRuntimeActivePersistenceTask(
                id: taskID,
                firstGeneration: queued.first?.generation ?? requestedGeneration,
                lastGeneration: queued.last?.generation ?? requestedGeneration,
                task: task
            )
        }
    }

    func enqueueStoreOperation(_ operation: AgentStoreWriteOperation) {
        nextStoreOperationGeneration &+= 1
        pendingStoreOperations.append(AgentRuntimePendingStoreOperation(
            generation: nextStoreOperationGeneration,
            operation: operation
        ))
    }

    private func clearActivePersistenceTask(id: UInt64) {
        guard activePersistenceTask?.id == id else { return }
        activePersistenceTask = nil
    }

    private func hasUnfinishedPersistence(through generation: UInt64) -> Bool {
        if let activePersistenceTask, activePersistenceTask.firstGeneration <= generation { return true }
        return pendingStoreOperations.contains { $0.generation <= generation }
    }

    private func finishPersistenceTask(id: UInt64) {
        clearActivePersistenceTask(id: id)
        guard !pendingStoreOperations.isEmpty else { return }
        // Keep draining accepted writes and cancellation records even when all
        // callers stop waiting before the store can acquire its lease.
        Task {
            do { try await self.persistState() }
            catch { logger.error(.persistence, "Deferred runtime persistence failed.",
                metadata: ["error": error.localizedDescription]) }
        }
    }

    private func makePersistenceBatch(
        _ operations: [AgentStoreWriteOperation]
    ) -> AgentRuntimePersistenceBatch {
        var orderedThreadIDs: [String] = []
        var operationsByThread: [String: [AgentStoreWriteOperation]] = [:]
        var deletedThreadIDs = Set<String>()
        for operation in operations {
            let threadID = operation.affectedThreadID
            if operationsByThread[threadID] == nil {
                orderedThreadIDs.append(threadID)
            }
            operationsByThread[threadID, default: []].append(operation)
            if case .deleteThread = operation {
                deletedThreadIDs.insert(threadID)
            }
        }
        let observationSnapshots = Dictionary(
            uniqueKeysWithValues: orderedThreadIDs.map { threadID in
                (
                    threadID,
                    AgentRuntimeObservationBatchSnapshot(
                        threadID: threadID,
                        threadSnapshot: makeThreadObservationSnapshot(for: threadID),
                        isDeletion: deletedThreadIDs.contains(threadID)
                    )
                )
            }
        )
        return AgentRuntimePersistenceBatch(
            orderedThreadIDs: orderedThreadIDs,
            operationsByThread: operationsByThread,
            observationSnapshots: observationSnapshots
        )
    }

    private func applyPersistenceBatch(
        _ batch: AgentRuntimePersistenceBatch
    ) async throws {
        var firstError: Error?
        for threadID in batch.orderedThreadIDs {
            do {
                try await persistenceCoordinator.apply(batch.operationsByThread[threadID] ?? [])
                if let snapshot = batch.observationSnapshots[threadID] {
                    await publishCommittedObservation(snapshot)
                }
            } catch {
                await recoverAfterPersistenceFailure(threadIDs: [threadID])
                if firstError == nil {
                    firstError = error
                }
            }
        }
        if let firstError {
            throw firstError
        }
    }

    func recoverAfterPersistenceFailure(threadIDs: Set<String>) async {
        for threadID in threadIDs {
            do {
                let activation = try await persistenceCoordinator.loadThreadActivationState(
                    id: threadID,
                    policy: threadActivationPolicy
                )
                installActivationState(activation)
            } catch {
                removeActiveState(for: threadID)
            }

            let pending = pendingStoreOperations
                .filter { $0.affectedThreadID == threadID }
                .map(\.operation)
            guard !pending.isEmpty else { continue }
            do {
                state = try state.applying(pending)
            } catch {
                pendingStoreOperations.removeAll { $0.affectedThreadID == threadID }
                logger.error(
                    .persistence,
                    "Discarded newer runtime mutations that could not be rebased after a failed write.",
                    metadata: ["thread_id": threadID]
                )
            }
        }
    }

    private func removeActiveState(for threadID: String) {
        state.threads.removeAll { $0.id == threadID }
        state.messagesByThread.removeValue(forKey: threadID)
        state.historyByThread.removeValue(forKey: threadID)
        state.summariesByThread.removeValue(forKey: threadID)
        state.contextStateByThread.removeValue(forKey: threadID)
        state.nextHistorySequenceByThread.removeValue(forKey: threadID)
        state.partiallyLoadedThreadIDs.remove(threadID)
    }

    /// Linear-time, last-write-wins coalescing. Thread deletion invalidates the
    /// thread's earlier slots without repeatedly scanning or shifting the array.
    func coalescedStoreOperations(
        _ operations: [AgentStoreWriteOperation]
    ) -> [AgentStoreWriteOperation] {
        var slots: [AgentStoreWriteOperation?] = []
        var latestIndexByKey: [AgentStoreWriteOperation.CoalescingKey: Int] = [:]
        var indexesByThread: [String: [Int]] = [:]

        for operation in operations {
            let threadID = operation.affectedThreadID
            if case .deleteThread = operation {
                for index in indexesByThread[threadID] ?? [] {
                    slots[index] = nil
                }
                indexesByThread[threadID] = []
            }

            if let key = operation.coalescingKey,
               let existingIndex = latestIndexByKey[key],
               slots[existingIndex] != nil {
                slots[existingIndex] = nil
            }

            let index = slots.count
            slots.append(operation)
            indexesByThread[threadID, default: []].append(index)
            if let key = operation.coalescingKey {
                latestIndexByKey[key] = index
            }
        }

        return slots.compactMap { $0 }
    }
}
