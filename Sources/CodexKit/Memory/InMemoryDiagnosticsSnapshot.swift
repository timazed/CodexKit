import Foundation

struct InMemoryDiagnosticsSnapshot: Sendable {
    private(set) var totalRecords = 0
    private(set) var activeRecords = 0
    private(set) var archivedRecords = 0
    private(set) var countsByScope: [MemoryScope: Int] = [:]
    private(set) var countsByCategory: [String: Int] = [:]

    init() {}

    init(records: [MemoryRecord]) {
        for record in records {
            addUnchecked(record)
        }
    }

    mutating func add(_ record: MemoryRecord) throws {
        let limit = MemoryStoreLimits.maximumDiagnosticDimensionValueCount
        guard countsByScope[record.scope] != nil || countsByScope.count < limit else {
            throw MemoryStoreError.invalidRecord(
                "namespace \(record.namespace) exceeds the diagnostics scope limit of \(limit)."
            )
        }
        guard countsByCategory[record.category] != nil || countsByCategory.count < limit else {
            throw MemoryStoreError.invalidRecord(
                "namespace \(record.namespace) exceeds the diagnostics category limit of \(limit)."
            )
        }
        addUnchecked(record)
    }

    mutating func remove(_ record: MemoryRecord) {
        totalRecords -= 1
        adjustStatus(record.status, by: -1)
        decrement(record.scope, in: &countsByScope)
        decrement(record.category, in: &countsByCategory)
    }

    mutating func transition(
        from oldStatus: MemoryRecordStatus,
        to newStatus: MemoryRecordStatus
    ) {
        guard oldStatus != newStatus else { return }
        adjustStatus(oldStatus, by: -1)
        adjustStatus(newStatus, by: 1)
    }

    func validateCardinality(namespace: String) throws {
        let limit = MemoryStoreLimits.maximumDiagnosticDimensionValueCount
        guard countsByScope.count <= limit, countsByCategory.count <= limit else {
            throw MemoryStoreError.invalidRecord(
                "namespace \(namespace) exceeds the diagnostics dimension limit of \(limit)."
            )
        }
    }

    func makeDiagnostics(
        namespace: String,
        implementation: String,
        schemaVersion: Int?
    ) -> MemoryStoreDiagnostics {
        MemoryStoreDiagnostics(
            namespace: namespace,
            implementation: implementation,
            schemaVersion: schemaVersion,
            totalRecords: totalRecords,
            activeRecords: activeRecords,
            archivedRecords: archivedRecords,
            countsByScope: countsByScope,
            countsByCategory: countsByCategory
        )
    }

    private mutating func addUnchecked(_ record: MemoryRecord) {
        totalRecords += 1
        adjustStatus(record.status, by: 1)
        countsByScope[record.scope, default: 0] += 1
        countsByCategory[record.category, default: 0] += 1
    }

    private mutating func adjustStatus(_ status: MemoryRecordStatus, by amount: Int) {
        switch status {
        case .active: activeRecords += amount
        case .archived: archivedRecords += amount
        }
    }

    private func decrement<Key: Hashable>(_ key: Key, in counts: inout [Key: Int]) {
        let updated = counts[key, default: 0] - 1
        if updated > 0 {
            counts[key] = updated
        } else {
            counts.removeValue(forKey: key)
        }
    }
}
