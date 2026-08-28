import Foundation
import RealmSwift

final class RealmRuntimeMetadataObject: Object {
    @Persisted(primaryKey: true) var id = "runtime"
    @Persisted var logicalSchemaVersion = 1
    @Persisted var storeSchemaVersion = 1
    @Persisted var legacyImportCompleted = false
}

final class RealmRuntimeAttachmentCleanupObject: Object {
    @Persisted(primaryKey: true) var storageKey = ""
}

/// Durable cursor for bounded attachment-reference cleanup after thread deletion.
final class RealmRuntimeDeletedThreadAttachmentObject: Object {
    @Persisted(primaryKey: true) var threadID = ""
}

final class RealmRuntimeAttachmentReferenceObject: Object {
    @Persisted(primaryKey: true) var key = ""
    @Persisted(indexed: true) var ownerType = ""
    @Persisted(indexed: true) var ownerKey = ""
    @Persisted(indexed: true) var threadID = ""
    @Persisted(indexed: true) var storageKey = ""
}

final class RealmRuntimeThreadObject: Object {
    @Persisted(primaryKey: true) var id = ""
    @Persisted(indexed: true) var createdAt = Date(timeIntervalSince1970: 0)
    @Persisted(indexed: true) var updatedAt = Date(timeIntervalSince1970: 0)
    @Persisted(indexed: true) var status = ""
    @Persisted var nextHistorySequence = 1
    @Persisted var encodedThread = Data()
}

final class RealmRuntimeSummaryObject: Object {
    @Persisted(primaryKey: true) var threadID = ""
    @Persisted(indexed: true) var createdAt = Date(timeIntervalSince1970: 0)
    @Persisted(indexed: true) var updatedAt = Date(timeIntervalSince1970: 0)
    @Persisted(indexed: true) var pendingStateKind: String?
    @Persisted var encodedSummary = Data()
}

final class RealmRuntimeHistoryObject: Object {
    @Persisted(primaryKey: true) var key = ""
    @Persisted(indexed: true) var recordID = ""
    @Persisted(indexed: true) var threadID = ""
    @Persisted(indexed: true) var sequenceNumber = 0
    @Persisted(indexed: true) var createdAt = Date(timeIntervalSince1970: 0)
    @Persisted(indexed: true) var kind = ""
    @Persisted(indexed: true) var turnID: String?
    @Persisted(indexed: true) var relationshipKey: String?
    @Persisted(indexed: true) var isCompactionMarker = false
    @Persisted(indexed: true) var isRedacted = false
    @Persisted(indexed: true) var messageRole: String?
    @Persisted(indexed: true) var hasStructuredOutput = false
    @Persisted(indexed: true) var systemEventType: String?
    @Persisted var encodedRecord = Data()
}

final class RealmRuntimeContextObject: Object {
    @Persisted(primaryKey: true) var threadID = ""
    @Persisted(indexed: true) var generation = 0
    @Persisted var encodedState = Data()
}

final class RealmRuntimeStructuredOutputObject: Object {
    @Persisted(primaryKey: true) var key = ""
    @Persisted(indexed: true) var threadID = ""
    @Persisted(indexed: true) var formatName = ""
    @Persisted(indexed: true) var committedAt = Date(timeIntervalSince1970: 0)
    @Persisted var encodedRecord = Data()
}

enum RealmRuntimeSchema {
    // Realm runtime persistence has not shipped. This is its complete v1 schema.
    static let version: UInt64 = 1

    static let objectTypes: [ObjectBase.Type] = [
        RealmRuntimeMetadataObject.self,
        RealmRuntimeThreadObject.self,
        RealmRuntimeSummaryObject.self,
        RealmRuntimeHistoryObject.self,
        RealmRuntimeContextObject.self,
        RealmRuntimeStructuredOutputObject.self,
        RealmRuntimeAttachmentCleanupObject.self,
        RealmRuntimeDeletedThreadAttachmentObject.self,
        RealmRuntimeAttachmentReferenceObject.self,
    ]
}
