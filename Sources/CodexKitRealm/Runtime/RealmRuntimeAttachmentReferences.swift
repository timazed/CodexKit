import CodexKit
import RealmSwift

// These synchronous helpers operate on the Realm supplied by the owning actor.
enum RealmRuntimeAttachmentReferences {
    static func storageKeys(
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

    static func replace(
        ownerType: String,
        ownerKey: String,
        threadID: String,
        storageKeys: some Sequence<String>,
        in realm: Realm
    ) {
        Self.delete(ownerType: ownerType, ownerKey: ownerKey, in: realm)
        for storageKey in Set(storageKeys) {
            let object = RealmRuntimeAttachmentReferenceObject()
            object.key = Self.key(
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

    static func delete(
        ownerType: String,
        ownerKey: String,
        in realm: Realm
    ) {
        realm.delete(realm.objects(RealmRuntimeAttachmentReferenceObject.self)
            .filter("ownerType == %@ AND ownerKey == %@", ownerType, ownerKey))
    }

    private static func key(
        ownerType: String,
        ownerKey: String,
        storageKey: String
    ) -> String {
        "o\(ownerType.utf8.count):\(ownerType)k\(ownerKey.utf8.count):\(ownerKey)s\(storageKey)"
    }

    static func enqueueCleanup(
        _ storageKeys: some Sequence<String>,
        in realm: Realm
    ) {
        for storageKey in Set(storageKeys) {
            let object = RealmRuntimeAttachmentCleanupObject()
            object.storageKey = storageKey
            realm.add(object, update: .modified)
        }
    }
}
