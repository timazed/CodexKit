import CodexKit
import Foundation
import RealmSwift

extension RealmRuntimeStateStore {
    @discardableResult
    func drainDeletedThreadAttachmentBatch(in realm: Realm) async throws -> Bool {
        guard let deletion = realm.objects(RealmRuntimeDeletedThreadAttachmentObject.self)
            .sorted(byKeyPath: "threadID")
            .first else { return false }
        let references = Array(realm.objects(RealmRuntimeAttachmentReferenceObject.self)
            .filter("threadID == %@", deletion.threadID)
            .prefix(257))
        let batch = Array(references.prefix(256))
        let storageKeys = Set(batch.map(\.storageKey))
        try await realm.asyncWrite {
            realm.delete(batch)
            enqueueAttachmentCleanup(storageKeys, in: realm)
            if references.count <= 256 {
                realm.delete(deletion)
            }
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
                    try await self.performAttachmentMaintenanceBatchWithoutCoordination()
                }
                guard didWork else { return }
                await Task.yield()
            }
        } catch {
            logger.warning(
                .persistence,
                "Deferred Realm attachment cleanup will retry on the next store operation.",
                metadata: ["error": error.localizedDescription]
            )
        }
    }

    private func performAttachmentMaintenanceBatchWithoutCoordination() async throws -> Bool {
        let realm = try await openRealm()
        let drained = try await drainDeletedThreadAttachmentBatch(in: realm)
        let settled = try await settleAttachmentCleanupBatch(in: realm)
        return drained || settled
    }

    func referencedAttachmentStorageKeyBatch(
        after cursor: String?,
        limit: Int = 256,
        in realm: Realm
    ) -> [String] {
        var objects = realm.objects(RealmRuntimeAttachmentReferenceObject.self)
        if let cursor { objects = objects.filter("storageKey > %@", cursor) }
        return Array(objects
            .distinct(by: ["storageKey"])
            .sorted(byKeyPath: "storageKey")
            .prefix(limit)
            .map(\.storageKey))
    }

    func referencedAttachmentStorageKeys(
        among storageKeys: Set<String>,
        in realm: Realm
    ) throws -> Set<String> {
        guard !storageKeys.isEmpty else { return [] }
        return Set(realm.objects(RealmRuntimeAttachmentReferenceObject.self)
            .filter("storageKey IN %@", Array(storageKeys))
            .map(\.storageKey))
    }

    func attachmentReferenceStorageKeys(
        ownerType: String,
        ownerKey: String,
        in realm: Realm
    ) throws -> Set<String> {
        let limit = AgentStoreLimits.maximumImageCountPerWrite + 1
        let keys = Array(realm.objects(RealmRuntimeAttachmentReferenceObject.self)
            .filter("ownerType == %@ AND ownerKey == %@", ownerType, ownerKey)
            .prefix(limit)
            .map(\.storageKey))
        guard keys.count < limit else {
            throw AgentStoreError.invalidInput(
                "stored attachment references exceed their bounded limit"
            )
        }
        return Set(keys)
    }

    func replaceAttachmentReferences(
        ownerType: String,
        ownerKey: String,
        threadID: String,
        storageKeys: some Sequence<String>,
        in realm: Realm
    ) {
        deleteAttachmentReferences(ownerType: ownerType, ownerKey: ownerKey, in: realm)
        for storageKey in Set(storageKeys) {
            let object = RealmRuntimeAttachmentReferenceObject()
            object.key = Self.attachmentReferenceKey(
                ownerType: ownerType,
                ownerKey: ownerKey,
                storageKey: storageKey
            )
            object.ownerType = ownerType
            object.ownerKey = ownerKey
            object.threadID = threadID
            object.storageKey = storageKey
            realm.add(object, update: .modified)
        }
    }

    func deleteAttachmentReferences(
        ownerType: String,
        ownerKey: String,
        in realm: Realm
    ) {
        realm.delete(realm.objects(RealmRuntimeAttachmentReferenceObject.self)
            .filter("ownerType == %@ AND ownerKey == %@", ownerType, ownerKey))
    }

    static func attachmentReferenceKey(
        ownerType: String,
        ownerKey: String,
        storageKey: String
    ) -> String {
        "o\(ownerType.utf8.count):\(ownerType)k\(ownerKey.utf8.count):\(ownerKey)s\(storageKey)"
    }

    func enqueueAttachmentCleanup(
        _ storageKeys: some Sequence<String>,
        in realm: Realm
    ) {
        for storageKey in Set(storageKeys) {
            let object = RealmRuntimeAttachmentCleanupObject()
            object.storageKey = storageKey
            realm.add(object, update: .modified)
        }
    }

    func reconcileAttachments(in realm: Realm) async throws {
        guard attachmentStore.requiresFullReconciliation else {
            try await recoverPendingAttachmentPromotions(in: realm)
            try await settleAttachmentCleanup(in: realm)
            return
        }
        var referenceCursor: String?
        while true {
            let referencedStorageKeys = referencedAttachmentStorageKeyBatch(
                after: referenceCursor,
                in: realm
            )
            guard !referencedStorageKeys.isEmpty else { break }
            try attachmentStore.migrate(referencedStorageKeys)
            try await realm.asyncWrite {
                realm.delete(realm.objects(RealmRuntimeAttachmentCleanupObject.self)
                    .filter("storageKey IN %@", referencedStorageKeys))
            }
            referenceCursor = referencedStorageKeys.last
        }

        let iterator = attachmentStore.makeStorageKeyIterator()
        while true {
            let storageKeys = try iterator.nextBatch()
            guard !storageKeys.isEmpty else { break }
            let storageKeySet = Set(storageKeys)
            let referenced = try referencedAttachmentStorageKeys(
                among: storageKeySet,
                in: realm
            )
            let orphaned = storageKeySet.subtracting(referenced)
            if !orphaned.isEmpty {
                try await realm.asyncWrite {
                    enqueueAttachmentCleanup(orphaned, in: realm)
                }
            }
        }
        try await settleAttachmentCleanup(in: realm)
        try attachmentStore.completePendingPromotionRecovery()
        try attachmentStore.markFullReconciliationComplete()
    }

    private func recoverPendingAttachmentPromotions(in realm: Realm) async throws {
        let iterator = attachmentStore.makePendingPromotionStorageKeyIterator()
        while true {
            let pendingStorageKeys = Set(try iterator.nextBatch())
            guard !pendingStorageKeys.isEmpty else { break }
            let referencedStorageKeys = try referencedAttachmentStorageKeys(
                among: pendingStorageKeys,
                in: realm
            )
            try attachmentStore.remove(
                storageKeys: pendingStorageKeys.subtracting(referencedStorageKeys)
            )
        }
        try attachmentStore.completePendingPromotionRecovery()
    }

    func settleAttachmentCleanup(in realm: Realm) async throws {
        while try await settleAttachmentCleanupBatch(in: realm) {}
    }

    @discardableResult
    func settleAttachmentCleanupBatch(in realm: Realm) async throws -> Bool {
        let queuedStorageKeys = Set(realm.objects(RealmRuntimeAttachmentCleanupObject.self)
            .sorted(byKeyPath: "storageKey")
            .prefix(256)
            .map(\.storageKey))
        guard !queuedStorageKeys.isEmpty else { return false }
        let referencedStorageKeys = try referencedAttachmentStorageKeys(
            among: queuedStorageKeys,
            in: realm
        )
        try attachmentStore.remove(
            storageKeys: queuedStorageKeys.subtracting(referencedStorageKeys)
        )
        try await realm.asyncWrite {
            realm.delete(realm.objects(RealmRuntimeAttachmentCleanupObject.self)
                .filter("storageKey IN %@", Array(queuedStorageKeys)))
        }
        return true
    }

    func removeUnreferencedPromotedAttachments(
        _ storageKeys: Set<String>,
        in realm: Realm
    ) async throws {
        guard !storageKeys.isEmpty else { return }
        let referencedStorageKeys = try referencedAttachmentStorageKeys(
            among: storageKeys,
            in: realm
        )
        try attachmentStore.remove(
            storageKeys: storageKeys.subtracting(referencedStorageKeys)
        )
    }

    func resetPerformanceDiagnostics() {
        latestApplyDecodedHistoryRecordCount = 0
        latestQueryDecodedHistoryRecordCount = 0
    }

    func performanceDiagnostics() -> (
        applyDecodedHistoryRecordCount: Int,
        queryDecodedHistoryRecordCount: Int
    ) {
        (latestApplyDecodedHistoryRecordCount, latestQueryDecodedHistoryRecordCount)
    }

    func shouldImportLegacyState(in realm: Realm) throws -> Bool {
        let importCompleted = realm.object(
            ofType: RealmRuntimeMetadataObject.self,
            forPrimaryKey: "runtime"
        )?.legacyImportCompleted ?? false
        guard let legacyStateURL,
              legacyStateURL != url,
              FileManager.default.fileExists(atPath: legacyStateURL.path),
              !importCompleted,
              realm.objects(RealmRuntimeThreadObject.self).isEmpty
        else {
            return false
        }
        return true
    }

    func importLegacyState() async throws {
        guard let legacyStateURL else { return }
        let legacyStore = FileRuntimeStateStore(url: legacyStateURL, logging: logging)
        let state = try await legacyStore.loadState()
        try await persistState(state, legacyImportCompleted: true)
        logger.info(.persistence, "Imported legacy runtime state into Realm.", metadata: ["legacy_url": legacyStateURL.path])
    }

    static func defaultLegacyImportURL(for realmURL: URL) -> URL? {
        guard realmURL.pathExtension.lowercased() != "json" else { return nil }
        return realmURL.deletingPathExtension().appendingPathExtension("json")
    }
}
