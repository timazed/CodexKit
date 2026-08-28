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
        if isPrepared { return }

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
