import CodexKit
@testable import CodexKitRealm
import Foundation
import RealmSwift
import XCTest

final class HostApplicationRealmObject: Object {
    @Persisted(primaryKey: true) var id = ""
    @Persisted var value = ""
}

final class RealmMemoryStoreBuilderTests: XCTestCase {
    func testManagedStorageUsesBundleScopedAdapterFiles() {
        let applicationSupportURL = URL(fileURLWithPath: "/tmp/application-support")
        let layout = CodexKitManagedStorageLayout(
            applicationSupportDirectory: applicationSupportURL,
            hostIdentifier: "com.example.host"
        )

        let realmRuntimeURL = layout.fileURL(for: .realmRuntime)
        let realmMemoryURL = layout.fileURL(for: .realmMemory)
        let sqliteRuntimeURL = layout.fileURL(for: .sqliteRuntime)
        let sqliteMemoryURL = layout.fileURL(for: .sqliteMemory)

        XCTAssertEqual(
            realmRuntimeURL.path,
            "/tmp/application-support/com.example.host/CodexKit/Realm/runtime-state.realm"
        )
        XCTAssertEqual(
            realmMemoryURL.path,
            "/tmp/application-support/com.example.host/CodexKit/Realm/memory.realm"
        )
        XCTAssertEqual(
            sqliteRuntimeURL.path,
            "/tmp/application-support/com.example.host/CodexKit/SQLite/runtime-state.sqlite"
        )
        XCTAssertEqual(
            sqliteMemoryURL.path,
            "/tmp/application-support/com.example.host/CodexKit/SQLite/memory.sqlite"
        )
        XCTAssertEqual(
            Set([realmRuntimeURL, realmMemoryURL, sqliteRuntimeURL, sqliteMemoryURL]).count,
            4
        )
    }

    func testBuilderCreatesPersistentMemoryStore() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("memory.realm")
        let record = MemoryRecord(
            id: "builder-record",
            namespace: "assistant",
            scope: "test",
            category: "fact",
            summary: "Built through the Realm memory store builder"
        )

        let store = try RealmMemoryStore.builder(url: url)
            .logging(.disabled)
            .build()
        try await store.put(record)

        let reopened = try RealmMemoryStoreBuilder(url: url).build()
        let loaded = try await reopened.record(id: record.id, namespace: record.namespace)
        XCTAssertEqual(loaded, record)
    }

    func testConfigurationBuilderConnectsTheCodexMigrationAndSchema() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("memory.realm")

        let configuration = RealmMemoryStoreConfigurationBuilder(fileURL: url).build()

        XCTAssertEqual(configuration.fileURL, url)
        XCTAssertEqual(configuration.schemaVersion, RealmMemoryStoreMigration.schemaVersion)
        XCTAssertNotNil(configuration.migrationBlock)
        XCTAssertEqual(
            Set(configuration.objectTypes?.map { $0.className() } ?? []),
            Set(RealmMemorySchema.objectTypes.map { $0.className() })
        )
    }

    @MainActor
    func testHostApplicationRealmAndMemoryStoreUseIndependentSchemas() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let hostURL = directory.appendingPathComponent("application.realm")
        let memoryURL = directory.appendingPathComponent("memory.realm")
        let hostConfiguration = Realm.Configuration(
            fileURL: hostURL,
            schemaVersion: 47,
            objectTypes: [HostApplicationRealmObject.self]
        )

        try autoreleasepool {
            let hostRealm = try Realm(configuration: hostConfiguration)
            try hostRealm.write {
                let object = HostApplicationRealmObject()
                object.id = "host-record"
                object.value = "owned by the host application"
                hostRealm.add(object)
            }
            hostRealm.invalidate()
        }

        let memoryStore = try RealmMemoryStore.builder(url: memoryURL).build()
        try await memoryStore.put(MemoryRecord(
            id: "memory-record",
            namespace: "assistant",
            scope: "test",
            category: "fact",
            summary: "Owned by CodexKit"
        ))

        try autoreleasepool {
            let hostRealm = try Realm(configuration: hostConfiguration)
            XCTAssertEqual(
                hostRealm.object(
                    ofType: HostApplicationRealmObject.self,
                    forPrimaryKey: "host-record"
                )?.value,
                "owned by the host application"
            )
            XCTAssertNil(hostRealm.schema[RealmMemoryRecord.className()])
            hostRealm.invalidate()
        }

        let loaded = try await memoryStore.record(
            id: "memory-record",
            namespace: "assistant"
        )
        XCTAssertNotNil(loaded)
    }

    func testConcurrentStoreInstancesUseRealmNativeWriteSerialization() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("memory.realm")
        let stores = try (0 ..< 4).map { _ in
            try RealmMemoryStore.builder(url: url).build()
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0 ..< 100 {
                let store = stores[index % stores.count]
                group.addTask {
                    try await store.put(MemoryRecord(
                        id: "record-\(index)",
                        namespace: "assistant",
                        scope: "stress",
                        category: "fact",
                        summary: "Concurrent Realm write \(index)"
                    ))
                }
            }
            try await group.waitForAll()
        }

        let records = try await stores[0].list(
            MemoryRecordListQuery(namespace: "assistant", limit: 200)
        )
        XCTAssertEqual(records.count, 100)
        let diagnostics = try await stores[0].diagnostics(namespace: "assistant")
        XCTAssertEqual(diagnostics.totalRecords, 100)
    }

    @MainActor
    func testUnreleasedRealmMemorySchemaStartsAtVersionOne() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("memory.realm")
        let store = try RealmMemoryStore.builder(url: url).build()
        try await store.prepare()
        XCTAssertEqual(RealmMemoryStoreMigration.schemaVersion, 1)
        try autoreleasepool {
            let realm = try Realm(
                configuration: RealmMemoryStoreConfigurationBuilder(fileURL: url).build()
            )
            XCTAssertEqual(realm.configuration.schemaVersion, 1)
            realm.invalidate()
        }
    }

    @MainActor
    func testDanglingRealmLinkFailsUpsertAsAnIntegrityError() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("memory.realm")
        let claimKey = RealmMemoryKey.make(namespace: "assistant", id: "dangling")
        let configuration = RealmMemoryStoreConfigurationBuilder(fileURL: url).build()

        try autoreleasepool {
            let realm = try Realm(configuration: configuration)
            try realm.write {
                let claim = RealmMemoryDedupeClaim()
                claim.key = claimKey
                realm.add(claim)
            }
            realm.invalidate()
        }

        let store = try RealmMemoryStore.builder(url: url).build()
        do {
            try await store.upsert(MemoryRecord(
                id: "replacement",
                namespace: "assistant",
                scope: "test",
                category: "fact",
                summary: "Must not hide corrupted ownership"
            ), dedupeKey: "dangling")
            XCTFail("Expected a corrupt dedupe claim error.")
        } catch {
            XCTAssertEqual(
                error as? RealmMemoryStoreIntegrityError,
                .corruptDedupeClaim(claimKey)
            )
        }

        let replacement = try await store.record(id: "replacement", namespace: "assistant")
        XCTAssertNil(replacement)
    }

    @MainActor
    func testMissingRealmDedupeClaimFailsClosedForInsertAndUpsert() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("memory.realm")
        let claimKey = RealmMemoryKey.make(namespace: "assistant", id: "shared")
        let store = try RealmMemoryStore.builder(url: url).build()
        try await store.put(MemoryRecord(
            id: "original",
            namespace: "assistant",
            scope: "test",
            category: "fact",
            summary: "Original",
            dedupeKey: "shared"
        ))

        let configuration = RealmMemoryStoreConfigurationBuilder(fileURL: url).build()
        try autoreleasepool {
            let realm = try Realm(configuration: configuration)
            let claim = try XCTUnwrap(realm.object(
                ofType: RealmMemoryDedupeClaim.self,
                forPrimaryKey: claimKey
            ))
            try realm.write { realm.delete(claim) }
            realm.invalidate()
        }

        let mutations: [() async throws -> Void] = [
            { try await store.put(MemoryRecord(
                id: "insert",
                namespace: "assistant",
                scope: "test",
                category: "fact",
                summary: "Insert",
                dedupeKey: "shared"
            )) },
            { try await store.upsert(MemoryRecord(
                id: "upsert",
                namespace: "assistant",
                scope: "test",
                category: "fact",
                summary: "Upsert"
            ), dedupeKey: "shared") },
        ]
        for mutation in mutations {
            do {
                try await mutation()
                XCTFail("Expected missing ownership to fail closed.")
            } catch {
                XCTAssertEqual(
                    error as? RealmMemoryStoreIntegrityError,
                    .corruptDedupeClaim(claimKey)
                )
            }
        }

        let records = try await store.list(MemoryRecordListQuery(namespace: "assistant"))
        XCTAssertEqual(records.map(\.id), ["original"])
    }

    @MainActor
    func testBulkDeleteRejectsSwappedDedupeOwnershipAtomically() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("memory.realm")
        let store = try RealmMemoryStore.builder(url: url).build()
        let records = [
            MemoryRecord(
                id: "first",
                namespace: "assistant",
                scope: "test",
                category: "fact",
                summary: "First",
                dedupeKey: "claim-first"
            ),
            MemoryRecord(
                id: "second",
                namespace: "assistant",
                scope: "test",
                category: "fact",
                summary: "Second",
                dedupeKey: "claim-second"
            ),
        ]
        try await store.putMany(records)

        let configuration = RealmMemoryStoreConfigurationBuilder(fileURL: url).build()
        try autoreleasepool {
            let realm = try Realm(configuration: configuration)
            let firstClaim = try XCTUnwrap(realm.object(
                ofType: RealmMemoryDedupeClaim.self,
                forPrimaryKey: RealmMemoryKey.make(namespace: "assistant", id: "claim-first")
            ))
            let secondClaim = try XCTUnwrap(realm.object(
                ofType: RealmMemoryDedupeClaim.self,
                forPrimaryKey: RealmMemoryKey.make(namespace: "assistant", id: "claim-second")
            ))
            let firstRecord = try XCTUnwrap(firstClaim.record)
            let secondRecord = try XCTUnwrap(secondClaim.record)
            try realm.write {
                firstClaim.record = secondRecord
                secondClaim.record = firstRecord
            }
            realm.invalidate()
        }

        do {
            try await store.delete(ids: records.map(\.id), namespace: "assistant")
            XCTFail("Expected swapped dedupe ownership to fail closed.")
        } catch {
            XCTAssertTrue(error is RealmMemoryStoreIntegrityError)
        }
        let remaining = try await store.list(
            MemoryRecordListQuery(namespace: "assistant")
        )
        XCTAssertEqual(remaining.count, 2)
        try autoreleasepool {
            let realm = try Realm(configuration: configuration)
            XCTAssertEqual(realm.objects(RealmMemoryDedupeClaim.self).count, 2)
            realm.invalidate()
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexKitRealmBuilderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }
}
