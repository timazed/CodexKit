import CodexKit
import RealmSwift

struct RealmMemoryNamespaceDiagnosticsDelta {
    var totalRecords = 0
    var activeRecords = 0
    var archivedRecords = 0
    var countsByScope: [String: Int] = [:]
    var countsByCategory: [String: Int] = [:]

    var isEmpty: Bool {
        totalRecords == 0 &&
            activeRecords == 0 &&
            archivedRecords == 0 &&
            countsByScope.values.allSatisfy { $0 == 0 } &&
            countsByCategory.values.allSatisfy { $0 == 0 }
    }
}

/// Coalesces a whole store operation before touching managed snapshots. Batch
/// writes therefore update each distinct counter once per transaction.
struct RealmMemoryDiagnosticsDelta {
    var byNamespace: [String: RealmMemoryNamespaceDiagnosticsDelta] = [:]

    mutating func add(_ record: MemoryRecord, by amount: Int) {
        add(
            namespace: record.namespace,
            status: record.status.rawValue,
            scope: record.scope.rawValue,
            category: record.category,
            by: amount
        )
    }

    mutating func add(_ record: RealmMemoryRecord, by amount: Int) {
        add(
            namespace: record.namespace,
            status: record.status,
            scope: record.scope,
            category: record.category,
            by: amount
        )
    }

    mutating func add(
        namespace: String,
        status: String,
        scope: String,
        category: String,
        by amount: Int
    ) {
        var delta = byNamespace[namespace, default: RealmMemoryNamespaceDiagnosticsDelta()]
        delta.totalRecords += amount
        adjustStatus(status, by: amount, in: &delta)
        delta.countsByScope[scope, default: 0] += amount
        delta.countsByCategory[category, default: 0] += amount
        byNamespace[namespace] = delta
    }

    mutating func addLegacyAggregate(
        namespace: String,
        dimension: String,
        value: String,
        count: Int
    ) {
        var delta = byNamespace[namespace, default: RealmMemoryNamespaceDiagnosticsDelta()]
        switch dimension {
        case "total":
            delta.totalRecords += count
        case "status":
            adjustStatus(value, by: count, in: &delta)
        case "scope":
            delta.countsByScope[value, default: 0] += count
        case "category":
            delta.countsByCategory[value, default: 0] += count
        default:
            break
        }
        byNamespace[namespace] = delta
    }

    mutating func transitionStatus(
        namespace: String,
        from oldStatus: String,
        to newStatus: String,
        by amount: Int = 1
    ) {
        guard oldStatus != newStatus, amount != 0 else { return }
        var delta = byNamespace[namespace, default: RealmMemoryNamespaceDiagnosticsDelta()]
        adjustStatus(oldStatus, by: -amount, in: &delta)
        adjustStatus(newStatus, by: amount, in: &delta)
        byNamespace[namespace] = delta
    }

    mutating func remove(
        namespace: String,
        totalRecords: Int,
        activeRecords: Int,
        archivedRecords: Int,
        countsByScope: [String: Int],
        countsByCategory: [String: Int]
    ) {
        guard totalRecords > 0 else { return }
        var delta = byNamespace[namespace, default: RealmMemoryNamespaceDiagnosticsDelta()]
        delta.totalRecords -= totalRecords
        delta.activeRecords -= activeRecords
        delta.archivedRecords -= archivedRecords
        for (scope, count) in countsByScope {
            delta.countsByScope[scope, default: 0] -= count
        }
        for (category, count) in countsByCategory {
            delta.countsByCategory[category, default: 0] -= count
        }
        byNamespace[namespace] = delta
    }

    private func adjustStatus(
        _ status: String,
        by amount: Int,
        in delta: inout RealmMemoryNamespaceDiagnosticsDelta
    ) {
        switch status {
        case MemoryRecordStatus.active.rawValue:
            delta.activeRecords += amount
        case MemoryRecordStatus.archived.rawValue:
            delta.archivedRecords += amount
        default:
            break
        }
    }
}

enum RealmMemoryDiagnosticsError: Error {
    case countUnderflow(namespace: String, dimension: String, value: String?)
    case countOverflow(namespace: String, dimension: String, value: String?)
    case inconsistentEmptySnapshot(namespace: String)
}

struct RealmMemoryDiagnosticsWriter {
    func removalDelta(
        for records: Results<RealmMemoryRecord>,
        namespace: String
    ) throws -> RealmMemoryDiagnosticsDelta {
        let totalRecords = records.count
        guard totalRecords > 0 else { return RealmMemoryDiagnosticsDelta() }

        let activeRecords = records
            .filter("status == %@", MemoryRecordStatus.active.rawValue)
            .count
        let archivedRecords = records
            .filter("status == %@", MemoryRecordStatus.archived.rawValue)
            .count
        var countsByScope: [String: Int] = [:]
        var countsByCategory: [String: Int] = [:]
        let dimensionLimit = MemoryStoreLimits.maximumDiagnosticDimensionValueCount + 1
        let scopes = Array(records.distinct(by: ["scope"])
            .prefix(dimensionLimit)
            .map(\.scope))
        let categories = Array(records.distinct(by: ["category"])
            .prefix(dimensionLimit)
            .map(\.category))
        guard scopes.count < dimensionLimit, categories.count < dimensionLimit else {
            throw MemoryStoreError.invalidRecord(
                "namespace \(namespace) exceeds the diagnostics dimension limit of \(MemoryStoreLimits.maximumDiagnosticDimensionValueCount)."
            )
        }
        countsByScope.reserveCapacity(scopes.count)
        for value in scopes {
            countsByScope[value] = records.filter("scope == %@", value).count
        }
        countsByCategory.reserveCapacity(categories.count)
        for value in categories {
            countsByCategory[value] = records.filter("category == %@", value).count
        }

        var delta = RealmMemoryDiagnosticsDelta()
        delta.remove(
            namespace: namespace,
            totalRecords: totalRecords,
            activeRecords: activeRecords,
            archivedRecords: archivedRecords,
            countsByScope: countsByScope,
            countsByCategory: countsByCategory
        )
        return delta
    }

    func setStatus(
        _ status: MemoryRecordStatus,
        for record: RealmMemoryRecord,
        delta: inout RealmMemoryDiagnosticsDelta
    ) {
        guard record.status != status.rawValue else { return }
        delta.transitionStatus(
            namespace: record.namespace,
            from: record.status,
            to: status.rawValue
        )
        record.status = status.rawValue
    }

    func apply(
        _ diagnosticsDelta: RealmMemoryDiagnosticsDelta,
        in realm: Realm
    ) throws {
        for (namespace, delta) in diagnosticsDelta.byNamespace where !delta.isEmpty {
            let snapshot: RealmMemoryDiagnosticsSnapshot
            if let existing = realm.object(
                ofType: RealmMemoryDiagnosticsSnapshot.self,
                forPrimaryKey: namespace
            ) {
                snapshot = existing
            } else {
                snapshot = RealmMemoryDiagnosticsSnapshot()
                snapshot.namespace = namespace
                realm.add(snapshot)
            }

            snapshot.totalRecords = try adjusted(
                snapshot.totalRecords,
                by: delta.totalRecords,
                namespace: namespace,
                dimension: "total"
            )
            snapshot.activeRecords = try adjusted(
                snapshot.activeRecords,
                by: delta.activeRecords,
                namespace: namespace,
                dimension: MemoryRecordStatus.active.rawValue
            )
            snapshot.archivedRecords = try adjusted(
                snapshot.archivedRecords,
                by: delta.archivedRecords,
                namespace: namespace,
                dimension: MemoryRecordStatus.archived.rawValue
            )
            try applyCounts(
                delta.countsByScope,
                namespace: namespace,
                dimension: "scope",
                to: snapshot.countsByScope
            )
            try applyCounts(
                delta.countsByCategory,
                namespace: namespace,
                dimension: "category",
                to: snapshot.countsByCategory
            )
            if snapshot.totalRecords == 0 {
                guard snapshot.activeRecords == 0,
                      snapshot.archivedRecords == 0,
                      snapshot.countsByScope.count == 0,
                      snapshot.countsByCategory.count == 0 else {
                    throw RealmMemoryDiagnosticsError.inconsistentEmptySnapshot(
                        namespace: namespace
                    )
                }
                realm.delete(snapshot)
            }
        }
    }

    func validateCardinality(_ snapshot: RealmMemoryDiagnosticsSnapshot) throws {
        let limit = MemoryStoreLimits.maximumDiagnosticDimensionValueCount
        guard snapshot.countsByScope.count <= limit,
              snapshot.countsByCategory.count <= limit else {
            throw MemoryStoreError.invalidRecord(
                "namespace \(snapshot.namespace) exceeds the diagnostics dimension limit of \(limit)."
            )
        }
    }

    private func applyCounts(
        _ deltas: [String: Int],
        namespace: String,
        dimension: String,
        to counts: Map<String, Int>
    ) throws {
        for (value, delta) in deltas where delta != 0 {
            if delta > 0,
               counts[value] == nil,
               counts.count >= MemoryStoreLimits.maximumDiagnosticDimensionValueCount {
                throw MemoryStoreError.invalidRecord(
                    "namespace \(namespace) exceeds the \(dimension) diagnostics limit of \(MemoryStoreLimits.maximumDiagnosticDimensionValueCount)."
                )
            }
            let current = counts[value] ?? 0
            let (updatedCount, overflow) = current.addingReportingOverflow(delta)
            guard !overflow else {
                throw RealmMemoryDiagnosticsError.countOverflow(
                    namespace: namespace,
                    dimension: dimension,
                    value: value
                )
            }
            guard updatedCount >= 0 else {
                throw RealmMemoryDiagnosticsError.countUnderflow(
                    namespace: namespace,
                    dimension: dimension,
                    value: value
                )
            }
            if updatedCount > 0 {
                counts[value] = updatedCount
            } else {
                counts.removeObject(for: value)
            }
        }
    }

    private func adjusted(
        _ current: Int,
        by delta: Int,
        namespace: String,
        dimension: String
    ) throws -> Int {
        let (value, overflow) = current.addingReportingOverflow(delta)
        guard !overflow else {
            throw RealmMemoryDiagnosticsError.countOverflow(
                namespace: namespace,
                dimension: dimension,
                value: nil
            )
        }
        guard value >= 0 else {
            throw RealmMemoryDiagnosticsError.countUnderflow(
                namespace: namespace,
                dimension: dimension,
                value: nil
            )
        }
        return value
    }
}
