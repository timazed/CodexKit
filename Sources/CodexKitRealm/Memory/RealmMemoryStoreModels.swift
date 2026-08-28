import Foundation
import RealmSwift

final class RealmMemoryRecord: Object {
    @Persisted(primaryKey: true) var key = ""
    @Persisted(indexed: true) var namespace = ""
    @Persisted(indexed: true) var recordID = ""
    @Persisted(indexed: true) var recordOrder: Int64 = 0
    @Persisted(indexed: true) var dedupeKey: String?
    @Persisted(indexed: true) var dedupeClaimKey: String?
    @Persisted(indexed: true) var status = ""
    @Persisted(indexed: true) var scope = ""
    @Persisted(indexed: true) var category = ""
    @Persisted var summary = ""
    @Persisted var evidence = List<String>()
    @Persisted var importance = 0.0
    /// Realm cannot index Double columns. Valid importance values are
    /// nonnegative, so their IEEE-754 bit pattern preserves numeric order.
    @Persisted(indexed: true) var importanceRank: Int64 = 0
    @Persisted(indexed: true) var createdAt = Date(timeIntervalSince1970: 0)
    @Persisted var observedAt: Date?
    @Persisted(indexed: true) var effectiveAt = Date(timeIntervalSince1970: 0)
    @Persisted(indexed: true) var expiresAt: Date?
    @Persisted var tagEntities = List<RealmMemoryTag>()
    @Persisted var relatedIDEntities = List<RealmMemoryRelatedID>()
    @Persisted var searchTokenEntities = List<RealmMemorySearchToken>()
    @Persisted var isPinned = false
    @Persisted var attributesJSON: Data?
    @Persisted(indexed: true) var renderedCharacterCount = 0
}

final class RealmMemoryTag: EmbeddedObject {
    @Persisted var ordinal = 0
    @Persisted(indexed: true) var value = ""
}

final class RealmMemoryRelatedID: EmbeddedObject {
    @Persisted var ordinal = 0
    @Persisted(indexed: true) var value = ""
}

final class RealmMemorySearchToken: EmbeddedObject {
    @Persisted(indexed: true) var value = ""
}

final class RealmMemoryDedupeClaim: Object {
    @Persisted(primaryKey: true) var key = ""
    @Persisted var record: RealmMemoryRecord?
}

final class RealmMemoryMetadata: Object {
    @Persisted(primaryKey: true) var id = "memory"
    @Persisted var diagnosticsProjectionVersion = 0
    @Persisted var recordProjectionVersion = 0
}

/// One materialized diagnostics row per namespace. The maps are Realm-native
/// collections, so individual counters are updated without encoding a blob.
final class RealmMemoryDiagnosticsSnapshot: Object {
    @Persisted(primaryKey: true) var namespace = ""
    @Persisted var totalRecords = 0
    @Persisted var activeRecords = 0
    @Persisted var archivedRecords = 0
    @Persisted var countsByScope = Map<String, Int>()
    @Persisted var countsByCategory = Map<String, Int>()
}
