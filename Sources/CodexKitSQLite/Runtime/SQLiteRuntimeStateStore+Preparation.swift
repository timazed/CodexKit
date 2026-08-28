import CodexKit
import Foundation
import GRDB

extension SQLiteRuntimeStateStore {
    func ensurePrepared() async throws {
        if isPrepared {
            return
        }

        let task: Task<Void, Error>
        let generation: UInt64
        if let preparationTask {
            task = preparationTask
            generation = preparationGeneration
        } else {
            preparationGeneration &+= 1
            generation = preparationGeneration
            let created = Task { try await self.performPreparation() }
            preparationTask = created
            task = created
        }

        do {
            try await task.value
            if preparationGeneration == generation {
                isPrepared = true
                preparationTask = nil
            }
        } catch {
            if preparationGeneration == generation {
                preparationTask = nil
            }
            throw error
        }
    }

    private func performPreparation() async throws {
        try await RuntimeStoreMutationCoordinator.shared.perform(
            for: attachmentStore.rootURL
        ) {
            try await self.performPreparationWithoutCoordination()
        }
    }

    private func performPreparationWithoutCoordination() async throws {
        logger.info(.persistence, "Preparing SQLite runtime state store.", metadata: ["url": url.path])
        let version = try await readUserVersion()
        guard version <= Self.currentStoreSchemaVersion else {
            throw AgentStoreError.migrationFailed(
                "Unsupported future SQLite runtime store schema version \(version)."
            )
        }

        try migrator.migrate(dbQueue)
        try attachmentStore.prepare()
        try attachmentStore.removeAbandonedStagingFiles()
        if try await shouldImportLegacyState() {
            logger.info(
                .persistence,
                "Importing legacy file runtime state into SQLite store.",
                metadata: ["legacy_url": legacyStateURL?.path ?? ""]
            )
            try await importLegacyState()
        }
        try await reconcileAttachments()
        logger.info(.persistence, "SQLite runtime state store prepared.", metadata: ["url": url.path])
    }

    func reconcileAttachments() async throws {
        guard attachmentStore.requiresFullReconciliation else {
            try await recoverPendingAttachmentPromotions()
            try await settleAttachmentCleanup()
            return
        }
        let persistence = self.persistence
        var referenceCursor: String?
        while true {
            let cursor = referenceCursor
            let referencedStorageKeys = try await dbQueue.read { db in
                try persistence.referencedAttachmentStorageKeyBatch(
                    after: cursor,
                    in: db
                )
            }
            guard !referencedStorageKeys.isEmpty else { break }
            try attachmentStore.migrate(referencedStorageKeys)
            _ = try await dbQueue.write { db in
                try RuntimeAttachmentCleanupRow
                    .filter(referencedStorageKeys.contains(Column("storageKey")))
                    .deleteAll(db)
            }
            referenceCursor = referencedStorageKeys.last
        }

        let iterator = attachmentStore.makeStorageKeyIterator()
        while true {
            let storageKeys = try iterator.nextBatch()
            guard !storageKeys.isEmpty else { break }
            let storageKeySet = Set(storageKeys)
            let referenced = try await dbQueue.read { db in
                try persistence.referencedAttachmentStorageKeys(
                    among: storageKeySet,
                    in: db
                )
            }
            let orphaned = storageKeySet.subtracting(referenced)
            if !orphaned.isEmpty {
                try await dbQueue.write { db in
                    try persistence.enqueueAttachmentCleanup(orphaned, in: db)
                }
            }
        }
        try await settleAttachmentCleanup()
        try attachmentStore.completePendingPromotionRecovery()
        try attachmentStore.markFullReconciliationComplete()
    }

    private func recoverPendingAttachmentPromotions() async throws {
        let persistence = self.persistence
        let iterator = attachmentStore.makePendingPromotionStorageKeyIterator()
        while true {
            let pendingStorageKeys = Set(try iterator.nextBatch())
            guard !pendingStorageKeys.isEmpty else { break }
            let referencedStorageKeys = try await dbQueue.read { db in
                try persistence.referencedAttachmentStorageKeys(
                    among: pendingStorageKeys,
                    in: db
                )
            }
            try attachmentStore.remove(
                storageKeys: pendingStorageKeys.subtracting(referencedStorageKeys)
            )
        }
        try attachmentStore.completePendingPromotionRecovery()
    }

    func removeUnreferencedPromotedAttachments(
        _ storageKeys: Set<String>
    ) async throws {
        guard !storageKeys.isEmpty else { return }
        let persistence = self.persistence
        let referenced = try await dbQueue.read { db in
            try persistence.referencedAttachmentStorageKeys(among: storageKeys, in: db)
        }
        try attachmentStore.remove(storageKeys: storageKeys.subtracting(referenced))
    }

    func settleAttachmentCleanup() async throws {
        while try await settleAttachmentCleanupBatch() {}
    }

    @discardableResult
    func settleAttachmentCleanupBatch() async throws -> Bool {
        let persistence = self.persistence
        let queuedStorageKeys = try await dbQueue.read { db in
            Set(try RuntimeAttachmentCleanupRow
                .order(Column("storageKey").asc)
                .limit(256)
                .fetchAll(db)
                .map(\.storageKey))
        }
        guard !queuedStorageKeys.isEmpty else { return false }
        let referencedStorageKeys = try await dbQueue.read { db in
            try persistence.referencedAttachmentStorageKeys(
                among: queuedStorageKeys,
                in: db
            )
        }
        try attachmentStore.remove(
            storageKeys: queuedStorageKeys.subtracting(referencedStorageKeys)
        )
        _ = try await dbQueue.write { db in
            try RuntimeAttachmentCleanupRow
                .filter(Array(queuedStorageKeys).contains(Column("storageKey")))
                .deleteAll(db)
        }
        return true
    }

    func scheduleAttachmentMaintenance() {
        guard attachmentMaintenanceTask == nil else { return }
        attachmentMaintenanceTask = Task { [weak self] in
            await self?.runAttachmentMaintenance()
        }
    }

    private func runAttachmentMaintenance() async {
        defer { attachmentMaintenanceTask = nil }
        do {
            while !Task.isCancelled {
                let didWork = try await RuntimeStoreMutationCoordinator.shared.perform(
                    for: attachmentStore.rootURL
                ) {
                    try await self.settleAttachmentCleanupBatch()
                }
                guard didWork else { return }
                await Task.yield()
            }
        } catch {
            logger.warning(
                .persistence,
                "Deferred SQLite attachment cleanup will retry on the next store operation.",
                metadata: ["error": error.localizedDescription]
            )
        }
    }
}
