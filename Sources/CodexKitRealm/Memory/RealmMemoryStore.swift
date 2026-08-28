import CodexKit
import Foundation
import RealmSwift

public actor RealmMemoryStore: MemoryStoring {
    private let logger: AgentLogger
    private let configuration: Realm.Configuration
    private let recordBuilder = RealmMemoryRecordBuilder()
    private let queryBuilder = RealmMemoryQueryBuilder()
    private let constraintsBuilder = RealmMemoryInsertionConstraintsBuilder()
    private let diagnosticsWriter = RealmMemoryDiagnosticsWriter()
    private let dedupeClaims = RealmMemoryDedupeClaimRepository()
    private let migrationInstanceID = UUID()
    private var realm: Realm?
    private var openingTask: Task<Void, Error>?
    private var openingGeneration: UInt64 = 0
    private var latestQueryMaterializedRecordCount = 0

    public static func builder(url: URL) -> RealmMemoryStoreBuilder {
        RealmMemoryStoreBuilder(url: url)
    }

    public init(
        url: URL,
        logging: AgentLoggingConfiguration = .disabled
    ) throws {
        let directory = url.deletingLastPathComponent()
        if !directory.path.isEmpty {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }

        let configuration = RealmMemoryStoreConfigurationBuilder(fileURL: url).build()
        self.logger = AgentLogger(configuration: logging)
        self.configuration = configuration
        logger.info(.memory, "Realm memory store configured.", metadata: ["url": url.path])
    }

    public func prepare() async throws {
        _ = try await openRealm()
    }

    public func put(_ record: MemoryRecord) async throws {
        try await RuntimeStoreMutationCoordinator.shared.perform(
            for: migrationCoordinationRootURL
        ) {
            try await self.putWithoutCoordination(record)
        }
    }

    private func putWithoutCoordination(_ record: MemoryRecord) async throws {
        try MemoryQueryEngine.validate(record)
        let constraints = try constraintsBuilder.build(for: [record])
        let writeBatch = try recordBuilder.buildBatch(from: [record])
        var diagnosticsDelta = RealmMemoryDiagnosticsDelta()
        diagnosticsDelta.add(record, by: 1)
        let realm = try await openRealm()

        try await realm.asyncWrite {
            try constraintsBuilder.ensureAvailable(constraints, in: realm)
            writeBatch.add(to: realm)
            try diagnosticsWriter.apply(diagnosticsDelta, in: realm)
        }
    }

    public func putMany(_ records: [MemoryRecord]) async throws {
        try await RuntimeStoreMutationCoordinator.shared.perform(
            for: migrationCoordinationRootURL
        ) {
            try await self.putManyWithoutCoordination(records)
        }
    }

    private func putManyWithoutCoordination(_ records: [MemoryRecord]) async throws {
        try MemoryQueryEngine.validateBulkRecords(records)
        let constraints = try constraintsBuilder.build(for: records)
        let writeBatch = try recordBuilder.buildBatch(from: records)
        var diagnosticsDelta = RealmMemoryDiagnosticsDelta()
        for record in records {
            diagnosticsDelta.add(record, by: 1)
        }
        let realm = try await openRealm()

        try await realm.asyncWrite {
            try constraintsBuilder.ensureAvailable(constraints, in: realm)
            writeBatch.add(to: realm)
            try diagnosticsWriter.apply(diagnosticsDelta, in: realm)
        }
    }

    public func upsert(_ record: MemoryRecord, dedupeKey: String) async throws {
        try await RuntimeStoreMutationCoordinator.shared.perform(
            for: migrationCoordinationRootURL
        ) {
            try await self.upsertWithoutCoordination(record, dedupeKey: dedupeKey)
        }
    }

    private func upsertWithoutCoordination(
        _ record: MemoryRecord,
        dedupeKey: String
    ) async throws {
        var replacement = record
        replacement.dedupeKey = dedupeKey
        try MemoryQueryEngine.validate(replacement)
        let writeBatch = try recordBuilder.buildBatch(from: [replacement])
        let realm = try await openRealm()

        try await realm.asyncWrite {
            var diagnosticsDelta = RealmMemoryDiagnosticsDelta()
            let claimKey = RealmMemoryKey.make(
                namespace: record.namespace,
                id: dedupeKey
            )
            try dedupeClaims.deleteRecordClaimed(
                by: claimKey,
                diagnosticsDelta: &diagnosticsDelta,
                in: realm
            )
            if let matchingID = realm.object(
                ofType: RealmMemoryRecord.self,
                forPrimaryKey: RealmMemoryKey.make(
                    namespace: record.namespace,
                    id: record.id
                )
            ) {
                try dedupeClaims.delete(
                    matchingID,
                    diagnosticsDelta: &diagnosticsDelta,
                    in: realm
                )
            }
            diagnosticsDelta.add(replacement, by: 1)
            writeBatch.add(to: realm, update: .modified)
            try diagnosticsWriter.apply(diagnosticsDelta, in: realm)
        }
    }

    public func query(_ query: MemoryQuery) async throws -> MemoryQueryResult {
        try MemoryQueryEngine.validate(query)
        latestQueryMaterializedRecordCount = 0
        let realm = try await openRealm()
        let now = Date()
        let queryTokens = MemoryQueryEngine.uniqueTokens(query.text)
        let minimumTextMatches = MemoryQueryEngine.requiredTextMatchCount(
            policy: query.textMatchPolicy,
            queryTokenCount: queryTokens.count
        )

        func candidates(for page: MemoryQuery) -> Results<RealmMemoryRecord> {
            var result = queryBuilder.buildCandidates(for: page, now: now, in: realm)
            if !queryTokens.isEmpty {
                result = result.filter(
                    "SUBQUERY(searchTokenEntities, $token, $token.value IN %@).@count >= %@",
                    queryTokens,
                    minimumTextMatches as NSNumber
                )
            }
            return result.filter(
                "renderedCharacterCount <= %@",
                page.maxCharacters as NSNumber
            )
        }

        guard query.limit > 0, query.maxCharacters > 0 else {
            return MemoryQueryResult(matches: [], truncated: !candidates(for: query).isEmpty)
        }

        var matches: [MemoryQueryMatch] = []
        let ranked = queryBuilder.buildRankedCandidates(
            from: candidates(for: query),
            profile: query.ranking
        )
        var iterator = ranked.makeIterator()
        var characterCount = 0
        var truncated = false
        while matches.count < query.limit {
            guard let object = iterator.next() else { break }
            let separatorCost = matches.isEmpty ? 0 : 1
            let remainingCharacters = query.maxCharacters - characterCount
            guard separatorCost <= remainingCharacters,
                  object.renderedCharacterCount <= remainingCharacters - separatorCost else {
                truncated = true
                break
            }
            let record = try recordBuilder.buildRecord(from: object)
            // Eligibility was already evaluated by the SUBQUERY above. Keep
            // the explanatory count in Realm too instead of re-searching the
            // selected object's token collection in Swift.
            let matchedTokenCount = queryTokens.isEmpty ? 0 : object
                .searchTokenEntities
                .filter("value IN %@", queryTokens)
                .count
            let match = MemoryQueryEngine.makeMatch(
                record: record,
                query: query,
                now: now,
                matchedTokenCount: matchedTokenCount,
                queryTokenCount: queryTokens.count,
                executionMethod: .databaseNative
            )
            matches.append(match)
            characterCount += object.renderedCharacterCount + separatorCost
        }
        if matches.count == query.limit, iterator.next() != nil {
            truncated = true
        }
        latestQueryMaterializedRecordCount = matches.count
        return MemoryQueryResult(
            matches: matches,
            truncated: truncated,
            nextCursor: truncated
                ? matches.last.map { MemoryQueryEngine.cursor(for: $0.record, query: query) }
                : nil
        )
    }

    public func record(id: String, namespace: String) async throws -> MemoryRecord? {
        try MemoryQueryEngine.validateNamespace(namespace)
        try MemoryQueryEngine.validateBulkIdentifiers([id], operation: "record lookup")
        let realm = try await openRealm()
        guard let object = realm.object(
            ofType: RealmMemoryRecord.self,
            forPrimaryKey: RealmMemoryKey.make(namespace: namespace, id: id)
        ) else { return nil }
        return try recordBuilder.buildRecord(from: object)
    }

    public func list(_ query: MemoryRecordListQuery) async throws -> [MemoryRecord] {
        try MemoryQueryEngine.validate(query)
        latestQueryMaterializedRecordCount = 0
        let realm = try await openRealm()
        let records = queryBuilder.buildList(for: query, in: realm)
        let limit = query.limit ?? MemoryStoreLimits.maximumListResultCount
        let selected = records.dropFirst(query.offset).prefix(limit)
        latestQueryMaterializedRecordCount = selected.count
        return try selected.map { try recordBuilder.buildRecord(from: $0) }
    }

    public func diagnostics(namespace: String) async throws -> MemoryStoreDiagnostics {
        try MemoryQueryEngine.validateNamespace(namespace)
        let realm = try await openRealm()
        let snapshot = realm.object(
            ofType: RealmMemoryDiagnosticsSnapshot.self,
            forPrimaryKey: namespace
        )
        var countsByScope: [MemoryScope: Int] = [:]
        var countsByCategory: [String: Int] = [:]
        if let snapshot {
            try diagnosticsWriter.validateCardinality(snapshot)
            countsByScope.reserveCapacity(snapshot.countsByScope.count)
            for (scope, count) in snapshot.countsByScope {
                countsByScope[MemoryScope(rawValue: scope)] = count
            }
            countsByCategory.reserveCapacity(snapshot.countsByCategory.count)
            for (category, count) in snapshot.countsByCategory {
                countsByCategory[category] = count
            }
        }
        return MemoryStoreDiagnostics(
            namespace: namespace,
            implementation: "realm",
            schemaVersion: Int(RealmMemoryStoreMigration.schemaVersion),
            totalRecords: snapshot?.totalRecords ?? 0,
            activeRecords: snapshot?.activeRecords ?? 0,
            archivedRecords: snapshot?.archivedRecords ?? 0,
            countsByScope: countsByScope,
            countsByCategory: countsByCategory
        )
    }

    public func compact(_ request: MemoryCompactionRequest) async throws {
        try await RuntimeStoreMutationCoordinator.shared.perform(
            for: migrationCoordinationRootURL
        ) {
            try await self.compactWithoutCoordination(request)
        }
    }

    private func compactWithoutCoordination(
        _ request: MemoryCompactionRequest
    ) async throws {
        try MemoryQueryEngine.validate(request)
        let constraints = try constraintsBuilder.build(for: [request.replacement])
        let writeBatch = try recordBuilder.buildBatch(from: [request.replacement])
        let sourceKeys = storageKeys(
            for: request.sourceIDs,
            namespace: request.replacement.namespace
        )
        let realm = try await openRealm()

        try await realm.asyncWrite {
            var diagnosticsDelta = RealmMemoryDiagnosticsDelta()
            try constraintsBuilder.ensureAvailable(constraints, in: realm)
            diagnosticsDelta.add(request.replacement, by: 1)
            writeBatch.add(to: realm)
            if !sourceKeys.isEmpty {
                let sources = realm.objects(RealmMemoryRecord.self)
                    .filter("key IN %@", sourceKeys)
                let activeSources = sources.filter(
                    "status == %@",
                    MemoryRecordStatus.active.rawValue
                )
                let archivedCount = activeSources.count
                if archivedCount > 0 {
                    diagnosticsDelta.transitionStatus(
                        namespace: request.replacement.namespace,
                        from: MemoryRecordStatus.active.rawValue,
                        to: MemoryRecordStatus.archived.rawValue,
                        by: archivedCount
                    )
                    activeSources.setValue(
                        MemoryRecordStatus.archived.rawValue,
                        forKey: "status"
                    )
                }
            }
            try diagnosticsWriter.apply(diagnosticsDelta, in: realm)
        }
    }

    public func archive(ids: [String], namespace: String) async throws {
        try await RuntimeStoreMutationCoordinator.shared.perform(
            for: migrationCoordinationRootURL
        ) {
            try await self.archiveWithoutCoordination(ids: ids, namespace: namespace)
        }
    }

    private func archiveWithoutCoordination(
        ids: [String],
        namespace: String
    ) async throws {
        try MemoryQueryEngine.validateNamespace(namespace)
        try MemoryQueryEngine.validateBulkIdentifiers(ids, operation: "archive")
        let keys = storageKeys(for: ids, namespace: namespace)
        guard !keys.isEmpty else { return }
        let realm = try await openRealm()

        try await realm.asyncWrite {
            var diagnosticsDelta = RealmMemoryDiagnosticsDelta()
            let records = realm.objects(RealmMemoryRecord.self).filter("key IN %@", keys)
            let activeRecords = records.filter(
                "status == %@",
                MemoryRecordStatus.active.rawValue
            )
            let archivedCount = activeRecords.count
            if archivedCount > 0 {
                diagnosticsDelta.transitionStatus(
                    namespace: namespace,
                    from: MemoryRecordStatus.active.rawValue,
                    to: MemoryRecordStatus.archived.rawValue,
                    by: archivedCount
                )
                activeRecords.setValue(
                    MemoryRecordStatus.archived.rawValue,
                    forKey: "status"
                )
            }
            try diagnosticsWriter.apply(diagnosticsDelta, in: realm)
        }
    }

    public func delete(ids: [String], namespace: String) async throws {
        try await RuntimeStoreMutationCoordinator.shared.perform(
            for: migrationCoordinationRootURL
        ) {
            try await self.deleteWithoutCoordination(ids: ids, namespace: namespace)
        }
    }

    private func deleteWithoutCoordination(
        ids: [String],
        namespace: String
    ) async throws {
        try MemoryQueryEngine.validateNamespace(namespace)
        try MemoryQueryEngine.validateBulkIdentifiers(ids, operation: "delete")
        let keys = storageKeys(for: ids, namespace: namespace)
        guard !keys.isEmpty else { return }
        let realm = try await openRealm()

        try await realm.asyncWrite {
            let records = realm.objects(RealmMemoryRecord.self)
                .filter("key IN %@", keys)
            let claims = realm.objects(RealmMemoryDedupeClaim.self)
                .filter("record.key IN %@", keys)
            let diagnosticsDelta = try dedupeClaims.deleteAll(
                records: records,
                claims: claims,
                namespace: namespace,
                diagnosticsWriter: diagnosticsWriter,
                in: realm
            )
            try diagnosticsWriter.apply(diagnosticsDelta, in: realm)
        }
    }

    @discardableResult
    public func pruneExpired(now: Date, namespace: String) async throws -> Int {
        try await RuntimeStoreMutationCoordinator.shared.perform(
            for: migrationCoordinationRootURL
        ) {
            try await self.pruneExpiredWithoutCoordination(now: now, namespace: namespace)
        }
    }

    private func pruneExpiredWithoutCoordination(
        now: Date,
        namespace: String
    ) async throws -> Int {
        try MemoryQueryEngine.validateNamespace(namespace)
        let realm = try await openRealm()

        return try await realm.asyncWrite {
            let expired = realm.objects(RealmMemoryRecord.self).filter(
                "namespace == %@ AND status == %@ AND isPinned == false AND expiresAt != nil AND expiresAt <= %@",
                namespace,
                MemoryRecordStatus.active.rawValue,
                now as NSDate
            )
            let count = expired.count
            let claims = realm.objects(RealmMemoryDedupeClaim.self).filter(
                "record.namespace == %@ AND record.status == %@ AND record.isPinned == false "
                    + "AND record.expiresAt != nil AND record.expiresAt <= %@",
                namespace,
                MemoryRecordStatus.active.rawValue,
                now as NSDate
            )
            let diagnosticsDelta = try dedupeClaims.deleteAll(
                records: expired,
                claims: claims,
                namespace: namespace,
                diagnosticsWriter: diagnosticsWriter,
                in: realm
            )
            try diagnosticsWriter.apply(diagnosticsDelta, in: realm)
            return count
        }
    }

    func resetPerformanceDiagnostics() {
        latestQueryMaterializedRecordCount = 0
    }

    func performanceDiagnostics() -> Int {
        latestQueryMaterializedRecordCount
    }

    private func openRealm() async throws -> Realm {
        if let realm {
            return realm
        }
        let task: Task<Void, Error>
        let generation: UInt64
        if let openingTask {
            task = openingTask
            generation = openingGeneration
        } else {
            openingGeneration &+= 1
            generation = openingGeneration
            task = Task { try await self.performOpen() }
            openingTask = task
        }
        do {
            try await task.value
            if openingGeneration == generation {
                openingTask = nil
            }
            guard let realm else {
                throw RealmMemoryStorePreparationError.openedRealmUnavailable
            }
            return realm
        } catch {
            if openingGeneration == generation {
                openingTask = nil
            }
            throw error
        }
    }

    private func performOpen() async throws {
        guard realm == nil else { return }
        let openedRealm = try await Realm.open(configuration: configuration)
        try await backfillRecordProjectionsIfNeeded(in: openedRealm)
        try await backfillDiagnosticsIfNeeded(in: openedRealm)
        realm = openedRealm
        logger.info(.memory, "Realm memory store prepared.")
    }

    private func storageKeys(for ids: [String], namespace: String) -> [String] {
        Set(ids).map { RealmMemoryKey.make(namespace: namespace, id: $0) }
    }

}

extension RealmMemoryStore: StoreMigrationIdentifying, StoreMigrationCoordinating {
    package nonisolated var storeMigrationIdentity: StoreMigrationIdentity {
        guard let url = configuration.fileURL else {
            return StoreMigrationIdentity(kind: "memory", instanceID: migrationInstanceID)
        }
        return StoreMigrationIdentity(kind: "memory", url: url)
    }

    package nonisolated var migrationCoordinationRootURL: URL {
        guard let url = configuration.fileURL else {
            return StoreMigrationCoordinationRoot.memoryStore(
                at: FileManager.default.temporaryDirectory
                    .appendingPathComponent(migrationInstanceID.uuidString)
            )
        }
        return StoreMigrationCoordinationRoot.memoryStore(at: url)
    }
}

private enum RealmMemoryStorePreparationError: Error {
    case openedRealmUnavailable
}
