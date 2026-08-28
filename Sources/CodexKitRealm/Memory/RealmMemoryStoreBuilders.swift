import CodexKit
import Foundation
import RealmSwift

/// Fluent construction for a memory store while keeping its Realm file and
/// migration policy owned by CodexKit.
public struct RealmMemoryStoreBuilder: Sendable {
    private let url: URL
    private var loggingConfiguration: AgentLoggingConfiguration = .disabled

    public init(url: URL) {
        self.url = url
    }

    public func logging(_ configuration: AgentLoggingConfiguration) -> Self {
        var builder = self
        builder.loggingConfiguration = configuration
        return builder
    }

    public func build() throws -> RealmMemoryStore {
        try RealmMemoryStore(url: url, logging: loggingConfiguration)
    }
}

struct RealmMemoryStoreConfigurationBuilder {
    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func build() -> Realm.Configuration {
        Realm.Configuration(
            fileURL: fileURL,
            schemaVersion: RealmMemoryStoreMigration.schemaVersion,
            migrationBlock: RealmMemoryStoreMigration.migrationBlock,
            objectTypes: RealmMemorySchema.objectTypes
        )
    }
}

enum RealmMemorySchema {
    static let objectTypes: [ObjectBase.Type] = [
        RealmMemoryRecord.self,
        RealmMemoryTag.self,
        RealmMemoryRelatedID.self,
        RealmMemorySearchToken.self,
        RealmMemoryDedupeClaim.self,
        RealmMemoryMetadata.self,
        RealmMemoryDiagnosticsSnapshot.self,
    ]
}

enum RealmMemoryKey {
    static func make(namespace: String, id: String) -> String {
        "\(namespace.utf8.count):\(namespace)\(id)"
    }
}

struct RealmMemoryRecordBuilder {
    func buildBatch(from records: [MemoryRecord]) throws -> RealmMemoryRecordWriteBatch {
        var unclaimedRecords: [RealmMemoryRecord] = []
        var claims: [RealmMemoryDedupeClaim] = []
        unclaimedRecords.reserveCapacity(records.count)
        claims.reserveCapacity(records.count)

        for record in records {
            let object = try build(from: record)
            if let claim = buildDedupeClaim(for: object) {
                claims.append(claim)
            } else {
                unclaimedRecords.append(object)
            }
        }
        return RealmMemoryRecordWriteBatch(
            unclaimedRecords: unclaimedRecords,
            claims: claims
        )
    }

    func build(from record: MemoryRecord) throws -> RealmMemoryRecord {
        let object = RealmMemoryRecord()
        object.key = RealmMemoryKey.make(namespace: record.namespace, id: record.id)
        object.namespace = record.namespace
        object.recordID = record.id
        object.recordOrder = MemoryQueryEngine.recordOrder(for: record.id)
        object.dedupeKey = record.dedupeKey
        object.dedupeClaimKey = record.dedupeKey.map {
            RealmMemoryKey.make(namespace: record.namespace, id: $0)
        }
        object.status = record.status.rawValue
        object.scope = record.scope.rawValue
        object.category = record.category
        object.summary = record.summary
        object.evidence.append(objectsIn: record.evidence)
        object.importance = record.importance
        object.importanceRank = MemoryQueryEngine.importanceRank(for: record.importance)
        object.createdAt = record.createdAt
        object.observedAt = record.observedAt
        object.effectiveAt = record.effectiveDate
        object.expiresAt = record.expiresAt
        object.tagEntities.append(objectsIn: buildTags(record.tags))
        object.relatedIDEntities.append(objectsIn: buildRelatedIDs(record.relatedIDs))
        object.searchTokenEntities.append(objectsIn: buildSearchTokens(record))
        object.isPinned = record.isPinned
        object.attributesJSON = try record.attributes.map { try JSONEncoder().encode($0) }
        object.renderedCharacterCount = MemoryQueryEngine.renderedCharacterCount(for: record)
        return object
    }

    func buildRecord(
        from object: RealmMemoryRecord,
        validateProjections: Bool = true
    ) throws -> MemoryRecord {
        guard object.evidence.count <= MemoryStoreLimits.maximumEvidenceCount,
              object.tagEntities.count <= MemoryStoreLimits.maximumTagCount,
              object.relatedIDEntities.count <= MemoryStoreLimits.maximumRelatedIDCount,
              !validateProjections ||
                object.searchTokenEntities.count <= MemoryStoreLimits.maximumStoredSearchTokenCount else {
            throw MemoryStoreError.invalidRecord(
                "stored memory collections exceed their bounded limits."
            )
        }
        guard let status = MemoryRecordStatus(rawValue: object.status) else {
            throw MemoryStoreError.invalidRecord(
                "stored memory status is invalid."
            )
        }
        let record = MemoryRecord(
            id: object.recordID,
            namespace: object.namespace,
            scope: MemoryScope(rawValue: object.scope),
            category: object.category,
            summary: object.summary,
            evidence: Array(object.evidence),
            importance: object.importance,
            createdAt: object.createdAt,
            observedAt: object.observedAt,
            expiresAt: object.expiresAt,
            tags: object.tagEntities.sorted(by: { $0.ordinal < $1.ordinal }).map(\.value),
            relatedIDs: object.relatedIDEntities.sorted(by: { $0.ordinal < $1.ordinal }).map(\.value),
            dedupeKey: object.dedupeKey,
            isPinned: object.isPinned,
            attributes: try decodeAttributes(object.attributesJSON),
            status: status
        )
        try MemoryQueryEngine.validate(record)
        guard !validateProjections || (
            object.key == RealmMemoryKey.make(namespace: record.namespace, id: record.id) &&
                object.recordOrder == MemoryQueryEngine.recordOrder(for: record.id) &&
                object.importanceRank == MemoryQueryEngine.importanceRank(for: record.importance) &&
                object.dedupeClaimKey == record.dedupeKey.map {
                    RealmMemoryKey.make(namespace: record.namespace, id: $0)
                } &&
                object.effectiveAt == record.effectiveDate &&
                object.renderedCharacterCount == MemoryQueryEngine.renderedCharacterCount(for: record)
        ) else {
            throw MemoryStoreError.invalidRecord(
                "stored memory payload does not match its indexed projections."
            )
        }
        return record
    }

    func rebuildProjections(on object: RealmMemoryRecord) throws {
        let record = try buildRecord(from: object, validateProjections: false)
        object.recordOrder = MemoryQueryEngine.recordOrder(for: record.id)
        object.importanceRank = MemoryQueryEngine.importanceRank(for: record.importance)
        object.dedupeClaimKey = record.dedupeKey.map {
            RealmMemoryKey.make(namespace: record.namespace, id: $0)
        }
        object.effectiveAt = record.effectiveDate
        object.renderedCharacterCount = MemoryQueryEngine.renderedCharacterCount(for: record)
        object.searchTokenEntities.removeAll()
        object.searchTokenEntities.append(objectsIn: buildSearchTokens(record))
    }

    private func decodeAttributes(_ data: Data?) throws -> JSONValue? {
        guard let data else { return nil }
        guard data.count <= MemoryStoreLimits.maximumAttributesByteCount else {
            throw MemoryStoreError.invalidRecord(
                "stored attributes exceed the supported size limit."
            )
        }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    private func buildDedupeClaim(for record: RealmMemoryRecord) -> RealmMemoryDedupeClaim? {
        guard let dedupeKey = record.dedupeKey else { return nil }
        let claim = RealmMemoryDedupeClaim()
        claim.key = RealmMemoryKey.make(namespace: record.namespace, id: dedupeKey)
        claim.record = record
        return claim
    }

    private func buildTags(_ tags: [String]) -> [RealmMemoryTag] {
        tags.enumerated().map { ordinal, value in
            let entity = RealmMemoryTag()
            entity.ordinal = ordinal
            entity.value = value
            return entity
        }
    }

    private func buildRelatedIDs(_ relatedIDs: [String]) -> [RealmMemoryRelatedID] {
        relatedIDs.enumerated().map { ordinal, value in
            let entity = RealmMemoryRelatedID()
            entity.ordinal = ordinal
            entity.value = value
            return entity
        }
    }

    private func buildSearchTokens(_ record: MemoryRecord) -> [RealmMemorySearchToken] {
        let content = ([record.summary, record.category] + record.evidence + record.tags)
            .joined(separator: " ")
        return MemoryQueryEngine.tokenize(content).map { value in
            let entity = RealmMemorySearchToken()
            entity.value = value
            return entity
        }
    }
}

struct RealmMemoryRecordWriteBatch {
    let unclaimedRecords: [RealmMemoryRecord]
    let claims: [RealmMemoryDedupeClaim]

    func add(to realm: Realm, update: Realm.UpdatePolicy = .error) {
        realm.add(unclaimedRecords, update: update)
        realm.add(claims, update: update)
    }
}

struct RealmMemoryQueryBuilder {
    func buildCandidates(
        for query: MemoryQuery,
        now: Date,
        in realm: Realm
    ) -> Results<RealmMemoryRecord> {
        var records = realm.objects(RealmMemoryRecord.self)
            .filter("namespace == %@", query.namespace)
        if !query.includeArchived {
            records = records.filter("status == %@", MemoryRecordStatus.active.rawValue)
        }
        records = records.filter(
            "isPinned == true OR expiresAt == nil OR expiresAt > %@",
            now as NSDate
        )
        if !query.scopes.isEmpty {
            records = records.filter("scope IN %@", query.scopes.map(\.rawValue))
        }
        if !query.categories.isEmpty {
            records = records.filter("category IN %@", query.categories)
        }
        if !query.tags.isEmpty {
            records = records.filter("ANY tagEntities.value IN %@", query.tags)
        }
        if !query.relatedIDs.isEmpty {
            records = records.filter("ANY relatedIDEntities.value IN %@", query.relatedIDs)
        }
        if let minImportance = query.minImportance {
            records = records.filter(
                "importanceRank >= %@",
                MemoryQueryEngine.importanceRank(for: minImportance) as NSNumber
            )
        }
        if let recencyWindow = query.recencyWindow {
            records = records.filter(
                "effectiveAt >= %@",
                now.addingTimeInterval(-recencyWindow) as NSDate
            )
        }
        if let cursor = query.cursor {
            let importanceRank = MemoryQueryEngine.importanceRank(for: cursor.importance)
            switch query.ranking {
            case .importanceThenRecency:
                records = records.filter(
                    "importanceRank < %@ OR "
                        + "(importanceRank == %@ AND effectiveAt < %@) OR "
                        + "(importanceRank == %@ AND effectiveAt == %@ AND recordOrder > %@) OR "
                        + "(importanceRank == %@ AND effectiveAt == %@ AND recordOrder == %@ AND recordID > %@)",
                    importanceRank as NSNumber,
                    importanceRank as NSNumber, cursor.effectiveDate as NSDate,
                    importanceRank as NSNumber, cursor.effectiveDate as NSDate, cursor.recordOrder as NSNumber,
                    importanceRank as NSNumber, cursor.effectiveDate as NSDate,
                    cursor.recordOrder as NSNumber, cursor.recordID
                )
            case .recencyThenImportance:
                records = records.filter(
                    "effectiveAt < %@ OR "
                        + "(effectiveAt == %@ AND importanceRank < %@) OR "
                        + "(effectiveAt == %@ AND importanceRank == %@ AND recordOrder > %@) OR "
                        + "(effectiveAt == %@ AND importanceRank == %@ AND recordOrder == %@ AND recordID > %@)",
                    cursor.effectiveDate as NSDate,
                    cursor.effectiveDate as NSDate, importanceRank as NSNumber,
                    cursor.effectiveDate as NSDate, importanceRank as NSNumber, cursor.recordOrder as NSNumber,
                    cursor.effectiveDate as NSDate, importanceRank as NSNumber,
                    cursor.recordOrder as NSNumber, cursor.recordID
                )
            }
        }
        return records
    }

    func buildList(
        for query: MemoryRecordListQuery,
        in realm: Realm
    ) -> Results<RealmMemoryRecord> {
        var records = realm.objects(RealmMemoryRecord.self)
            .filter("namespace == %@", query.namespace)
        if !query.includeArchived {
            records = records.filter("status == %@", MemoryRecordStatus.active.rawValue)
        }
        if !query.scopes.isEmpty {
            records = records.filter("scope IN %@", query.scopes.map(\.rawValue))
        }
        if !query.categories.isEmpty {
            records = records.filter("category IN %@", query.categories)
        }
        if let cursor = query.cursor {
            records = records.filter(
                "effectiveAt < %@ OR (effectiveAt == %@ AND recordID > %@)",
                cursor.effectiveDate as NSDate,
                cursor.effectiveDate as NSDate,
                cursor.recordID
            )
        }
        return records.sorted(by: [
            SortDescriptor(keyPath: "effectiveAt", ascending: false),
            SortDescriptor(keyPath: "recordID", ascending: true),
        ])
    }

    /// Realm Core evaluates the complete filter and deterministic sort once.
    /// Callers may then advance the lazily evaluated ranked prefix without
    /// decoding records or repeating the native query for every result.
    func buildRankedCandidates(
        from candidates: Results<RealmMemoryRecord>,
        profile: MemoryRankingProfile
    ) -> Results<RealmMemoryRecord> {
        let primary: RealmSwift.SortDescriptor
        let secondary: RealmSwift.SortDescriptor
        switch profile {
        case .importanceThenRecency:
            primary = RealmSwift.SortDescriptor(keyPath: "importanceRank", ascending: false)
            secondary = RealmSwift.SortDescriptor(keyPath: "effectiveAt", ascending: false)
        case .recencyThenImportance:
            primary = RealmSwift.SortDescriptor(keyPath: "effectiveAt", ascending: false)
            secondary = RealmSwift.SortDescriptor(keyPath: "importanceRank", ascending: false)
        }
        return candidates.sorted(by: [
            primary,
            secondary,
            RealmSwift.SortDescriptor(keyPath: "recordOrder", ascending: true),
            RealmSwift.SortDescriptor(keyPath: "recordID", ascending: true),
        ])
    }
}

/// Prepared before the write begins so batch-local duplicate detection does
/// not extend Realm's single-writer transaction.
struct RealmMemoryInsertionConstraints {
    var recordKeys: [String] = []
    var dedupeKeys: [String] = []
    var dedupeKeyByStorageKey: [String: String] = [:]
}

struct RealmMemoryInsertionConstraintsBuilder {
    func build(for records: [MemoryRecord]) throws -> RealmMemoryInsertionConstraints {
        var constraints = RealmMemoryInsertionConstraints()
        constraints.recordKeys.reserveCapacity(records.count)
        constraints.dedupeKeys.reserveCapacity(records.count)
        constraints.dedupeKeyByStorageKey.reserveCapacity(records.count)
        var recordIDsByStorageKey: [String: String] = [:]
        recordIDsByStorageKey.reserveCapacity(records.count)

        for record in records {
            let recordKey = RealmMemoryKey.make(namespace: record.namespace, id: record.id)
            guard recordIDsByStorageKey.updateValue(record.id, forKey: recordKey) == nil else {
                throw MemoryStoreError.duplicateRecordID(record.id)
            }
            constraints.recordKeys.append(recordKey)

            if let dedupeKey = record.dedupeKey {
                let storageKey = RealmMemoryKey.make(
                    namespace: record.namespace,
                    id: dedupeKey
                )
                guard constraints.dedupeKeyByStorageKey.updateValue(
                    dedupeKey,
                    forKey: storageKey
                ) == nil else {
                    throw MemoryStoreError.duplicateDedupeKey(dedupeKey)
                }
                constraints.dedupeKeys.append(storageKey)
            }
        }
        return constraints
    }

    func ensureAvailable(
        _ constraints: RealmMemoryInsertionConstraints,
        in realm: Realm
    ) throws {
        if !constraints.recordKeys.isEmpty,
           let existing = realm.objects(RealmMemoryRecord.self)
               .filter("key IN %@", constraints.recordKeys)
               .first {
            throw MemoryStoreError.duplicateRecordID(existing.recordID)
        }
        guard !constraints.dedupeKeys.isEmpty else { return }

        if let existingRecord = realm.objects(RealmMemoryRecord.self)
            .filter("dedupeClaimKey IN %@", constraints.dedupeKeys)
            .first,
           let claimKey = existingRecord.dedupeClaimKey {
            let recordsForClaim = realm.objects(RealmMemoryRecord.self)
                .filter("dedupeClaimKey == %@", claimKey)
            let claim = realm.object(
                ofType: RealmMemoryDedupeClaim.self,
                forPrimaryKey: claimKey
            )
            guard recordsForClaim.count == 1,
                  claim?.record?.key == existingRecord.key else {
                throw RealmMemoryStoreIntegrityError.corruptDedupeClaim(claimKey)
            }
            if let dedupeKey = constraints.dedupeKeyByStorageKey[claimKey] {
                throw MemoryStoreError.duplicateDedupeKey(dedupeKey)
            }
        }

        if let existingClaim = realm.objects(RealmMemoryDedupeClaim.self)
            .filter("key IN %@", constraints.dedupeKeys)
            .first {
            guard let record = existingClaim.record,
                  record.dedupeClaimKey == existingClaim.key else {
                throw RealmMemoryStoreIntegrityError.corruptDedupeClaim(existingClaim.key)
            }
            if let dedupeKey = constraints.dedupeKeyByStorageKey[existingClaim.key] {
                throw MemoryStoreError.duplicateDedupeKey(dedupeKey)
            }
        }
    }
}
