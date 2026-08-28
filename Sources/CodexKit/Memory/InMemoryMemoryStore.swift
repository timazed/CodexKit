import Foundation

public actor InMemoryMemoryStore: MemoryStoring {
    private var recordsByNamespace: [String: [String: MemoryRecord]]
    private var diagnosticsByNamespace: [String: InMemoryDiagnosticsSnapshot]
    private let migrationInstanceID = UUID()

    public init(initialRecords: [MemoryRecord] = []) {
        recordsByNamespace = Dictionary(grouping: initialRecords, by: \.namespace)
            .mapValues { records in
                Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
            }
        diagnosticsByNamespace = Dictionary(
            uniqueKeysWithValues: recordsByNamespace.map { namespace, records in
                (namespace, InMemoryDiagnosticsSnapshot(records: Array(records.values)))
            }
        )
    }

    public func put(_ record: MemoryRecord) async throws {
        try MemoryQueryEngine.validate(record)
        var namespaceRecords = recordsByNamespace[record.namespace, default: [:]]
        guard namespaceRecords[record.id] == nil else {
            throw MemoryStoreError.duplicateRecordID(record.id)
        }

        if let dedupeKey = record.dedupeKey,
           namespaceRecords.values.contains(where: { $0.dedupeKey == dedupeKey }) {
            throw MemoryStoreError.duplicateDedupeKey(dedupeKey)
        }

        var diagnostics = diagnosticsByNamespace[
            record.namespace,
            default: InMemoryDiagnosticsSnapshot()
        ]
        try diagnostics.add(record)
        namespaceRecords[record.id] = record
        recordsByNamespace[record.namespace] = namespaceRecords
        diagnosticsByNamespace[record.namespace] = diagnostics
    }

    public func putMany(_ records: [MemoryRecord]) async throws {
        try MemoryQueryEngine.validateBulkRecords(records)
        var working = recordsByNamespace
        var workingDiagnostics = diagnosticsByNamespace

        for record in records {
            var namespaceRecords = working[record.namespace, default: [:]]
            guard namespaceRecords[record.id] == nil else {
                throw MemoryStoreError.duplicateRecordID(record.id)
            }
            if let dedupeKey = record.dedupeKey,
               namespaceRecords.values.contains(where: { $0.dedupeKey == dedupeKey }) {
                throw MemoryStoreError.duplicateDedupeKey(dedupeKey)
            }
            var diagnostics = workingDiagnostics[
                record.namespace,
                default: InMemoryDiagnosticsSnapshot()
            ]
            try diagnostics.add(record)
            namespaceRecords[record.id] = record
            working[record.namespace] = namespaceRecords
            workingDiagnostics[record.namespace] = diagnostics
        }

        recordsByNamespace = working
        diagnosticsByNamespace = workingDiagnostics
    }

    public func upsert(_ record: MemoryRecord, dedupeKey: String) async throws {
        var updatedRecord = record
        updatedRecord.dedupeKey = dedupeKey
        try MemoryQueryEngine.validate(updatedRecord)
        var namespaceRecords = recordsByNamespace[record.namespace, default: [:]]
        var diagnostics = diagnosticsByNamespace[
            record.namespace,
            default: InMemoryDiagnosticsSnapshot()
        ]

        var removedIDs = Set<String>()
        if let existing = namespaceRecords.values.first(where: { $0.dedupeKey == dedupeKey }) {
            removedIDs.insert(existing.id)
        }
        if namespaceRecords[record.id] != nil {
            removedIDs.insert(record.id)
        }
        for id in removedIDs {
            if let removed = namespaceRecords.removeValue(forKey: id) {
                diagnostics.remove(removed)
            }
        }

        try diagnostics.add(updatedRecord)
        namespaceRecords[updatedRecord.id] = updatedRecord
        recordsByNamespace[record.namespace] = namespaceRecords
        diagnosticsByNamespace[record.namespace] = diagnostics
    }

    public func query(_ query: MemoryQuery) async throws -> MemoryQueryResult {
        try MemoryQueryEngine.validate(query)
        let namespaceRecords = recordsByNamespace[query.namespace, default: [:]]
        let queryTokens = Set(MemoryQueryEngine.uniqueTokens(query.text))
        let candidates = namespaceRecords.values.map { record in
            MemoryQueryEngine.Candidate(
                record: record,
                matchedTokenCount: MemoryQueryEngine.matchedTokenCount(
                    for: record,
                    queryTokens: queryTokens
                ),
                queryTokenCount: queryTokens.count
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
        try MemoryQueryEngine.validateBulkIdentifiers([id], operation: "record lookup")
        return recordsByNamespace[namespace, default: [:]][id]
    }

    public func list(_ query: MemoryRecordListQuery) async throws -> [MemoryRecord] {
        try MemoryQueryEngine.validate(query)
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
                if let cursor = query.cursor {
                    if record.effectiveDate == cursor.effectiveDate {
                        return record.id > cursor.recordID
                    }
                    return record.effectiveDate < cursor.effectiveDate
                }
                return true
            }
            .sorted {
                if $0.effectiveDate == $1.effectiveDate {
                    return $0.id < $1.id
                }
                return $0.effectiveDate > $1.effectiveDate
            }
            .dropFirst(query.offset)
            .prefix(query.limit ?? MemoryStoreLimits.maximumListResultCount)
            .map { $0 }
    }

    public func diagnostics(namespace: String) async throws -> MemoryStoreDiagnostics {
        try MemoryQueryEngine.validateNamespace(namespace)
        let snapshot = diagnosticsByNamespace[
            namespace,
            default: InMemoryDiagnosticsSnapshot()
        ]
        try snapshot.validateCardinality(namespace: namespace)
        return snapshot.makeDiagnostics(
            namespace: namespace,
            implementation: "in_memory",
            schemaVersion: nil
        )
    }

    public func compact(_ request: MemoryCompactionRequest) async throws {
        try MemoryQueryEngine.validate(request)
        var working = recordsByNamespace
        let namespace = request.replacement.namespace
        var namespaceRecords = working[namespace, default: [:]]
        var diagnostics = diagnosticsByNamespace[
            namespace,
            default: InMemoryDiagnosticsSnapshot()
        ]

        guard namespaceRecords[request.replacement.id] == nil else {
            throw MemoryStoreError.duplicateRecordID(request.replacement.id)
        }
        if let dedupeKey = request.replacement.dedupeKey,
           namespaceRecords.values.contains(where: { $0.dedupeKey == dedupeKey }) {
            throw MemoryStoreError.duplicateDedupeKey(dedupeKey)
        }

        try diagnostics.add(request.replacement)
        namespaceRecords[request.replacement.id] = request.replacement
        for sourceID in request.sourceIDs {
            guard var existing = namespaceRecords[sourceID] else {
                continue
            }
            let oldStatus = existing.status
            existing.status = .archived
            namespaceRecords[sourceID] = existing
            diagnostics.transition(from: oldStatus, to: .archived)
        }

        working[namespace] = namespaceRecords
        recordsByNamespace = working
        diagnosticsByNamespace[namespace] = diagnostics
    }

    public func archive(ids: [String], namespace: String) async throws {
        try MemoryQueryEngine.validateNamespace(namespace)
        try MemoryQueryEngine.validateBulkIdentifiers(ids, operation: "archive")
        var namespaceRecords = recordsByNamespace[namespace, default: [:]]
        var diagnostics = diagnosticsByNamespace[
            namespace,
            default: InMemoryDiagnosticsSnapshot()
        ]
        for id in ids {
            guard var record = namespaceRecords[id] else {
                continue
            }
            let oldStatus = record.status
            record.status = .archived
            namespaceRecords[id] = record
            diagnostics.transition(from: oldStatus, to: .archived)
        }
        recordsByNamespace[namespace] = namespaceRecords
        diagnosticsByNamespace[namespace] = diagnostics
    }

    public func delete(ids: [String], namespace: String) async throws {
        try MemoryQueryEngine.validateNamespace(namespace)
        try MemoryQueryEngine.validateBulkIdentifiers(ids, operation: "delete")
        var namespaceRecords = recordsByNamespace[namespace, default: [:]]
        var diagnostics = diagnosticsByNamespace[
            namespace,
            default: InMemoryDiagnosticsSnapshot()
        ]
        for id in ids {
            if let removed = namespaceRecords.removeValue(forKey: id) {
                diagnostics.remove(removed)
            }
        }
        recordsByNamespace[namespace] = namespaceRecords
        diagnosticsByNamespace[namespace] = diagnostics
    }

    @discardableResult
    public func pruneExpired(
        now: Date,
        namespace: String
    ) async throws -> Int {
        try MemoryQueryEngine.validateNamespace(namespace)
        var namespaceRecords = recordsByNamespace[namespace, default: [:]]
        var diagnostics = diagnosticsByNamespace[
            namespace,
            default: InMemoryDiagnosticsSnapshot()
        ]
        let expiredIDs = namespaceRecords.values
            .filter { record in
                !record.isPinned &&
                    record.status == .active &&
                    (record.expiresAt?.compare(now) == .orderedAscending ||
                        record.expiresAt?.compare(now) == .orderedSame)
            }
            .map(\.id)

        for id in expiredIDs {
            if let removed = namespaceRecords.removeValue(forKey: id) {
                diagnostics.remove(removed)
            }
        }
        recordsByNamespace[namespace] = namespaceRecords
        diagnosticsByNamespace[namespace] = diagnostics
        return expiredIDs.count
    }
}

extension InMemoryMemoryStore: StoreMigrationIdentifying {
    package nonisolated var storeMigrationIdentity: StoreMigrationIdentity {
        StoreMigrationIdentity(kind: "memory", instanceID: migrationInstanceID)
    }
}
