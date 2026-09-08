import CodexKit
import RealmSwift

extension RealmMemoryStore {
    private static var recordProjectionVersion: Int { 1 }
    private static var recordProjectionBackfillBatchSize: Int { 32 }
    private static var diagnosticsProjectionVersion: Int { 1 }
    private static var diagnosticsBackfillBatchSize: Int { 64 }

    func backfillRecordProjectionsIfNeeded(in realm: Realm) async throws {
        let projectionBuilder = RealmMemoryRecordBuilder()
        let storedVersion = realm.object(
            ofType: RealmMemoryMetadata.self,
            forPrimaryKey: "memory"
        )?.recordProjectionVersion ?? 0
        guard storedVersion < Self.recordProjectionVersion else { return }

        var lastKey: String?
        while true {
            var records = realm.objects(RealmMemoryRecord.self)
            if let lastKey { records = records.filter("key > %@", lastKey) }
            let objects = Array(records
                .sorted(byKeyPath: "key")
                .prefix(Self.recordProjectionBackfillBatchSize))
            guard !objects.isEmpty else { break }
            try await realm.asyncWrite(_isolation: self) {
                for object in objects {
                    try projectionBuilder.rebuildProjections(on: object)
                }
            }
            lastKey = objects.last?.key
        }

        try await realm.asyncWrite(_isolation: self) {
            let metadata = realm.object(
                ofType: RealmMemoryMetadata.self,
                forPrimaryKey: "memory"
            ) ?? RealmMemoryMetadata()
            metadata.recordProjectionVersion = Self.recordProjectionVersion
            realm.add(metadata, update: .modified)
        }
    }

    func backfillDiagnosticsIfNeeded(in realm: Realm) async throws {
        let storedVersion = realm.object(
            ofType: RealmMemoryMetadata.self,
            forPrimaryKey: "memory"
        )?.diagnosticsProjectionVersion ?? 0
        guard storedVersion < Self.diagnosticsProjectionVersion else { return }

        var lastNamespace: String?
        while true {
            var records = realm.objects(RealmMemoryRecord.self)
            if let lastNamespace {
                records = records.filter("namespace > %@", lastNamespace)
            }
            let namespaces = Array(
                records.distinct(by: ["namespace"])
                    .sorted(byKeyPath: "namespace")
                    .prefix(Self.diagnosticsBackfillBatchSize)
            ).map(\.namespace)
            guard !namespaces.isEmpty else { break }

            try await realm.asyncWrite(_isolation: self) {
                for namespace in namespaces {
                    try rebuildDiagnosticsSnapshot(for: namespace, in: realm)
                }
            }
            lastNamespace = namespaces.last
        }

        try await realm.asyncWrite(_isolation: self) {
            let metadata = realm.object(
                ofType: RealmMemoryMetadata.self,
                forPrimaryKey: "memory"
            ) ?? RealmMemoryMetadata()
            metadata.diagnosticsProjectionVersion = Self.diagnosticsProjectionVersion
            realm.add(metadata, update: .modified)
        }
    }

    private func rebuildDiagnosticsSnapshot(
        for namespace: String,
        in realm: Realm
    ) throws {
        let records = realm.objects(RealmMemoryRecord.self)
            .filter("namespace == %@", namespace)
        let distinctLimit = MemoryStoreLimits.maximumDiagnosticDimensionValueCount + 1
        let scopes = Array(
            records.distinct(by: ["scope"])
                .sorted(byKeyPath: "scope")
                .prefix(distinctLimit)
        ).map(\.scope)
        let categories = Array(
            records.distinct(by: ["category"])
                .sorted(byKeyPath: "category")
                .prefix(distinctLimit)
        ).map(\.category)
        guard scopes.count < distinctLimit, categories.count < distinctLimit else {
            throw MemoryStoreError.invalidRecord(
                "namespace \(namespace) exceeds the diagnostics dimension limit of \(MemoryStoreLimits.maximumDiagnosticDimensionValueCount)."
            )
        }

        let snapshot = realm.object(
            ofType: RealmMemoryDiagnosticsSnapshot.self,
            forPrimaryKey: namespace
        ) ?? RealmMemoryDiagnosticsSnapshot()
        snapshot.namespace = namespace
        snapshot.totalRecords = records.count
        snapshot.activeRecords = records.filter(
            "status == %@",
            MemoryRecordStatus.active.rawValue
        ).count
        snapshot.archivedRecords = records.filter(
            "status == %@",
            MemoryRecordStatus.archived.rawValue
        ).count
        snapshot.countsByScope.removeAll()
        for scope in scopes {
            snapshot.countsByScope[scope] = records.filter("scope == %@", scope).count
        }
        snapshot.countsByCategory.removeAll()
        for category in categories {
            snapshot.countsByCategory[category] = records.filter(
                "category == %@",
                category
            ).count
        }
        realm.add(snapshot, update: .modified)
    }
}
