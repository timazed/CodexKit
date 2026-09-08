import CodexKit
import RealmSwift

extension RealmRuntimeStateStore {
    func openRealm() async throws -> Realm {
        if let realm {
            return realm
        }
        let openedRealm = try await Realm.open(configuration: configuration)
        realm = openedRealm
        return openedRealm
    }

    func ensurePrepared() async throws {
        try Task.checkCancellation()
        if isPrepared { return }
        if let preparationTask {
            try await preparationTask.value
            try Task.checkCancellation()
            return
        }
        preparationGeneration &+= 1
        let generation = preparationGeneration
        let task = RuntimeStoreTask<Void>(preservingCommits: false, inheritingCommitScope: false) {
            do {
                try await self.performPreparation()
                await self.finishPreparation(generation: generation, succeeded: true)
            } catch {
                await self.finishPreparation(generation: generation, succeeded: false)
                throw error
            }
        }
        preparationTask = task
        // Cancelling a waiter must not cancel or replace preparation shared by
        // another caller. The task owns state cleanup, even if every waiter leaves.
        try await task.value
        try Task.checkCancellation()
    }

    private func finishPreparation(generation: UInt64, succeeded: Bool) {
        guard preparationGeneration == generation else { return }
        isPrepared = succeeded
        preparationTask = nil
    }

    func performPreparation() async throws {
        try await RuntimeStoreMutationCoordinator.shared.perform(
            for: attachmentStore.rootURL
        ) {
            try await self.performPreparationWithoutCoordination()
        }
    }

    func performPreparationWithoutCoordination() async throws {
        try attachmentStore.prepare()
        try attachmentStore.removeAbandonedStagingFiles()
        let realm = try await openRealm()
        let storedVersion = realm.object(
            ofType: RealmRuntimeMetadataObject.self,
            forPrimaryKey: "runtime"
        )?.storeSchemaVersion ?? 0
        if storedVersion < Int(RealmRuntimeSchema.version) {
            try await backfillQueryProjectionsInBatches(in: realm)
            try await realm.asyncWrite {
                let metadata = realm.object(
                    ofType: RealmRuntimeMetadataObject.self,
                    forPrimaryKey: "runtime"
                ) ?? RealmRuntimeMetadataObject()
                metadata.storeSchemaVersion = Int(RealmRuntimeSchema.version)
                realm.add(metadata, update: .modified)
            }
        }
        if try shouldImportLegacyState(in: realm) {
            try await importLegacyState()
        }
        try await reconcileAttachments(in: realm)
        logger.info(.persistence, "Realm runtime state store prepared.", metadata: ["url": url.path])
    }
}
