import Foundation

public actor InMemoryMemoryStore: MemoryStoring {
    private var recordsByNamespace: [String: [String: MemoryRecord]]

    public init(initialRecords: [MemoryRecord] = []) {
        recordsByNamespace = Dictionary(grouping: initialRecords, by: \.namespace)
            .mapValues { records in
                Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
            }
    }

    public func put(_ record: MemoryRecord) async throws {
        try MemoryQueryEngine.validateNamespace(record.namespace)
        var namespaceRecords = recordsByNamespace[record.namespace, default: [:]]
        guard namespaceRecords[record.id] == nil else {
            throw MemoryStoreError.duplicateRecordID(record.id)
        }

        if let dedupeKey = record.dedupeKey,
           namespaceRecords.values.contains(where: { $0.dedupeKey == dedupeKey }) {
            throw MemoryStoreError.duplicateDedupeKey(dedupeKey)
        }

        namespaceRecords[record.id] = record
        recordsByNamespace[record.namespace] = namespaceRecords
    }

    public func putMany(_ records: [MemoryRecord]) async throws {
        var working = recordsByNamespace

        for record in records {
            try MemoryQueryEngine.validateNamespace(record.namespace)
            var namespaceRecords = working[record.namespace, default: [:]]
            guard namespaceRecords[record.id] == nil else {
                throw MemoryStoreError.duplicateRecordID(record.id)
            }
            if let dedupeKey = record.dedupeKey,
               namespaceRecords.values.contains(where: { $0.dedupeKey == dedupeKey }) {
                throw MemoryStoreError.duplicateDedupeKey(dedupeKey)
            }
            namespaceRecords[record.id] = record
            working[record.namespace] = namespaceRecords
        }

        recordsByNamespace = working
    }

    public func upsert(_ record: MemoryRecord, dedupeKey: String) async throws {
        try MemoryQueryEngine.validateNamespace(record.namespace)
        var namespaceRecords = recordsByNamespace[record.namespace, default: [:]]

        if let existing = namespaceRecords.values.first(where: { $0.dedupeKey == dedupeKey }) {
            namespaceRecords.removeValue(forKey: existing.id)
        } else if let existingByID = namespaceRecords[record.id],
                  existingByID.dedupeKey != nil,
                  existingByID.dedupeKey != dedupeKey {
            namespaceRecords.removeValue(forKey: existingByID.id)
        }

        var updatedRecord = record
        updatedRecord.dedupeKey = dedupeKey
        namespaceRecords[updatedRecord.id] = updatedRecord
        recordsByNamespace[record.namespace] = namespaceRecords
    }

    public func query(_ query: MemoryQuery) async throws -> MemoryQueryResult {
        try MemoryQueryEngine.validateNamespace(query.namespace)
        let namespaceRecords = recordsByNamespace[query.namespace, default: [:]]
        let candidates = namespaceRecords.values.map { record in
            MemoryQueryEngine.Candidate(
                record: record,
                textScore: MemoryQueryEngine.defaultTextScore(
                    for: record,
                    queryText: query.text
                ),
                textScoreOrdering: .higherIsBetter
            )
        }

        return try MemoryQueryEngine.evaluate(
            candidates: candidates,
            query: query
        )
    }

    public func record(
        id: String,
        namespace: String
    ) async throws -> MemoryRecord? {
        try MemoryQueryEngine.validateNamespace(namespace)
        return recordsByNamespace[namespace, default: [:]][id]
    }

    public func list(_ query: MemoryRecordListQuery) async throws -> [MemoryRecord] {
        try MemoryQueryEngine.validateNamespace(query.namespace)
        return recordsByNamespace[query.namespace, default: [:]]
            .values
            .filter { record in
                if !query.includeArchived, record.status == .archived {
                    return false
                }
                if !query.scopes.isEmpty, !query.scopes.contains(record.scope) {
                    return false
                }
                if !query.categories.isEmpty, !query.categories.contains(record.category) {
                    return false
                }
                return true
            }
            .sorted {
                if $0.effectiveDate == $1.effectiveDate {
                    return $0.id < $1.id
                }
                return $0.effectiveDate > $1.effectiveDate
            }
            .prefix(query.limit ?? .max)
            .map { $0 }
    }

    public func diagnostics(namespace: String) async throws -> MemoryStoreDiagnostics {
        try MemoryQueryEngine.validateNamespace(namespace)
        let records = Array(recordsByNamespace[namespace, default: [:]].values)
        return diagnostics(
            namespace: namespace,
            implementation: "in_memory",
            schemaVersion: nil,
            records: records
        )
    }

    public func compact(_ request: MemoryCompactionRequest) async throws {
        try MemoryQueryEngine.validateNamespace(request.replacement.namespace)
        var working = recordsByNamespace
        let namespace = request.replacement.namespace
        var namespaceRecords = working[namespace, default: [:]]

        guard namespaceRecords[request.replacement.id] == nil else {
            throw MemoryStoreError.duplicateRecordID(request.replacement.id)
        }
        if let dedupeKey = request.replacement.dedupeKey,
           namespaceRecords.values.contains(where: { $0.dedupeKey == dedupeKey }) {
            throw MemoryStoreError.duplicateDedupeKey(dedupeKey)
        }

        namespaceRecords[request.replacement.id] = request.replacement
        for sourceID in request.sourceIDs {
            guard var existing = namespaceRecords[sourceID] else {
                continue
            }
            existing.status = .archived
            namespaceRecords[sourceID] = existing
        }

        working[namespace] = namespaceRecords
        recordsByNamespace = working
    }

    public func archive(ids: [String], namespace: String) async throws {
        try MemoryQueryEngine.validateNamespace(namespace)
        var namespaceRecords = recordsByNamespace[namespace, default: [:]]
        for id in ids {
            guard var record = namespaceRecords[id] else {
                continue
            }
            record.status = .archived
            namespaceRecords[id] = record
        }
        recordsByNamespace[namespace] = namespaceRecords
    }

    public func delete(ids: [String], namespace: String) async throws {
        try MemoryQueryEngine.validateNamespace(namespace)
        var namespaceRecords = recordsByNamespace[namespace, default: [:]]
        for id in ids {
            namespaceRecords.removeValue(forKey: id)
        }
        recordsByNamespace[namespace] = namespaceRecords
    }

    @discardableResult
    public func pruneExpired(
        now: Date,
        namespace: String
    ) async throws -> Int {
        try MemoryQueryEngine.validateNamespace(namespace)
        var namespaceRecords = recordsByNamespace[namespace, default: [:]]
        let expiredIDs = namespaceRecords.values
            .filter { record in
                !record.isPinned &&
                    record.status == .active &&
                    (record.expiresAt?.compare(now) == .orderedAscending ||
                        record.expiresAt?.compare(now) == .orderedSame)
            }
            .map(\.id)

        for id in expiredIDs {
            namespaceRecords.removeValue(forKey: id)
        }
        recordsByNamespace[namespace] = namespaceRecords
        return expiredIDs.count
    }

    private func diagnostics(
        namespace: String,
        implementation: String,
        schemaVersion: Int?,
        records: [MemoryRecord]
    ) -> MemoryStoreDiagnostics {
        var countsByScope: [MemoryScope: Int] = [:]
        var countsByCategory: [String: Int] = [:]

        for record in records {
            countsByScope[record.scope, default: 0] += 1
            countsByCategory[record.category, default: 0] += 1
        }

        let activeRecords = records.filter { $0.status == .active }.count
        let archivedRecords = records.count - activeRecords

        return MemoryStoreDiagnostics(
            namespace: namespace,
            implementation: implementation,
            schemaVersion: schemaVersion,
            totalRecords: records.count,
            activeRecords: activeRecords,
            archivedRecords: archivedRecords,
            countsByScope: countsByScope,
            countsByCategory: countsByCategory
        )
    }
}
