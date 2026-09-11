import CodexKit
@testable import CodexKitSQLite
import Foundation
import SQLite3
import XCTest

final class MemoryStoreTests: XCTestCase {
    func testManagedSQLiteMemoryStoreLeavesHostDatabaseUntouched() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let hostURL = directory.appendingPathComponent("application.sqlite")
        let layout = CodexKitManagedStorageLayout(
            applicationSupportDirectory: directory,
            hostIdentifier: "com.example.host"
        )
        let memoryURL = layout.fileURL(for: .sqliteMemory)

        var hostDatabase: OpaquePointer?
        XCTAssertEqual(sqlite3_open(hostURL.path, &hostDatabase), SQLITE_OK)
        XCTAssertEqual(
            sqlite3_exec(
                hostDatabase,
                """
                CREATE TABLE host_records (id TEXT PRIMARY KEY, value TEXT NOT NULL);
                INSERT INTO host_records VALUES ('host-record', 'owned by the host');
                PRAGMA user_version = 47;
                """,
                nil,
                nil,
                nil
            ),
            SQLITE_OK
        )
        XCTAssertEqual(sqlite3_close(hostDatabase), SQLITE_OK)
        let hostDatabaseBefore = try Data(contentsOf: hostURL)

        let store = try SQLiteMemoryStore(url: memoryURL)
        try await store.put(MemoryRecord(
            id: "memory-record",
            namespace: "assistant",
            scope: "test",
            category: "fact",
            summary: "Owned by CodexKit"
        ))

        XCTAssertNotEqual(hostURL, memoryURL)
        XCTAssertEqual(try Data(contentsOf: hostURL), hostDatabaseBefore)
        let storedRecord = try await store.record(id: "memory-record", namespace: "assistant")
        XCTAssertNotNil(storedRecord)
    }

    func testSQLiteStorePersistsAndReloadsRecords() async throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try SQLiteMemoryStore(url: url)
        let record = MemoryRecord(
            namespace: "demo-assistant",
            scope: "feature:health-coach",
            category: "preference",
            summary: "Health Coach should use direct accountability when the user is behind on steps.",
            evidence: ["The user ignores soft reminders late in the day."],
            importance: 0.9,
            tags: ["steps", "tone"],
            relatedIDs: ["goal-10000"],
            dedupeKey: "health-coach-direct-accountability"
        )

        try await store.put(record)

        let reloaded = try SQLiteMemoryStore(url: url)
        let result = try await reloaded.query(
            MemoryQuery(
                namespace: "demo-assistant",
                scopes: ["feature:health-coach"],
                text: "direct steps reminder",
                limit: 5,
                maxCharacters: 600
            )
        )

        XCTAssertEqual(result.matches.map(\.record.id), [record.id])
        XCTAssertGreaterThan(result.matches[0].explanation.matchedTokenCount, 0)

        let diagnostics = try await reloaded.diagnostics(namespace: "demo-assistant")
        XCTAssertEqual(diagnostics.implementation, .sqlite)
        XCTAssertEqual(diagnostics.schemaVersion, SQLiteMemoryStoreSchema().currentVersion)
    }

    func testSQLiteMigratesReleasedVersionOneRecordsIntoStructuredTables() async throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let record = MemoryRecord(
            id: "migrated-structured",
            namespace: "assistant",
            scope: "project",
            category: "fact",
            summary: "The structured schema survives migration.",
            evidence: ["first", "second"],
            importance: 0.8,
            createdAt: Date(timeIntervalSince1970: 100),
            observedAt: Date(timeIntervalSince1970: 200),
            tags: ["legacy", "structured"],
            relatedIDs: ["project-1"],
            dedupeKey: "legacy-dedupe",
            isPinned: true,
            attributes: .object(["source": .string("legacy")])
        )

        var database: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(
                url.path,
                &database,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
                nil
            ),
            SQLITE_OK
        )
        XCTAssertEqual(
            sqlite3_exec(
                database,
                """
                CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY);
                INSERT INTO grdb_migrations VALUES ('memory_store_v1');
                CREATE TABLE memory_records (
                    namespace TEXT NOT NULL,
                    id TEXT NOT NULL,
                    scope TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    summary TEXT NOT NULL,
                    evidence_json TEXT NOT NULL,
                    importance DOUBLE NOT NULL,
                    created_at DOUBLE NOT NULL,
                    observed_at DOUBLE,
                    expires_at DOUBLE,
                    tags_json TEXT NOT NULL,
                    related_ids_json TEXT NOT NULL,
                    dedupe_key TEXT,
                    is_pinned BOOLEAN NOT NULL,
                    attributes_json TEXT,
                    status TEXT NOT NULL,
                    PRIMARY KEY (namespace, id)
                );
                CREATE TABLE memory_tags (namespace TEXT NOT NULL, record_id TEXT NOT NULL, tag TEXT NOT NULL);
                CREATE TABLE memory_related_ids (namespace TEXT NOT NULL, record_id TEXT NOT NULL, related_id TEXT NOT NULL);
                CREATE VIRTUAL TABLE memory_fts USING fts5(namespace UNINDEXED, record_id UNINDEXED, content);
                INSERT INTO memory_records VALUES (
                    'assistant', 'migrated-structured', 'project', 'fact',
                    'The structured schema survives migration.', '["first","second"]',
                    0.8, 100, 200, NULL, '["legacy","structured"]', '["project-1"]',
                    'legacy-dedupe', 1, '{"source":"legacy"}', 'active'
                );
                INSERT INTO memory_tags VALUES ('assistant', 'migrated-structured', 'legacy');
                INSERT INTO memory_tags VALUES ('assistant', 'migrated-structured', 'structured');
                INSERT INTO memory_related_ids VALUES ('assistant', 'migrated-structured', 'project-1');
                INSERT INTO memory_fts VALUES ('assistant', 'migrated-structured', 'structured schema first second legacy');
                PRAGMA user_version = 1;
                """,
                nil,
                nil,
                nil
            ),
            SQLITE_OK
        )
        XCTAssertEqual(sqlite3_close(database), SQLITE_OK)

        let migrated = try SQLiteMemoryStore(url: url)
        let result = try await migrated.query(MemoryQuery(
            namespace: record.namespace,
            text: "structured",
            tags: ["legacy"],
            relatedIDs: ["project-1"],
            minImportance: 0.75
        ))
        XCTAssertEqual(result.matches.map(\.record.id), [record.id])
        XCTAssertEqual(result.matches.first?.record, record)
        let diagnostics = try await migrated.diagnostics(namespace: record.namespace)
        XCTAssertEqual(diagnostics.schemaVersion, SQLiteMemoryStoreSchema().currentVersion)
    }

    func testSQLiteQueryPushesFiltersBeforeMaterializingRecords() async throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMemoryStore(url: url)
        let now = Date()
        let base = MemoryRecord(
            id: "matching",
            namespace: "assistant",
            scope: "feature:selected",
            category: "preference",
            summary: "The selected memory",
            importance: 0.8,
            createdAt: now,
            tags: ["selected-tag"],
            relatedIDs: ["selected-id"]
        )
        try await store.putMany([
            base,
            MemoryRecord(
                id: "wrong-scope",
                namespace: "assistant",
                scope: "feature:other",
                category: base.category,
                summary: "Wrong scope",
                importance: base.importance,
                createdAt: now,
                tags: base.tags,
                relatedIDs: base.relatedIDs
            ),
            MemoryRecord(
                id: "archived",
                namespace: base.namespace,
                scope: base.scope,
                category: base.category,
                summary: "Archived",
                importance: base.importance,
                createdAt: now,
                tags: base.tags,
                relatedIDs: base.relatedIDs,
                status: .archived
            ),
            MemoryRecord(
                id: "expired",
                namespace: base.namespace,
                scope: base.scope,
                category: base.category,
                summary: "Expired",
                importance: base.importance,
                createdAt: now,
                expiresAt: now.addingTimeInterval(-1),
                tags: base.tags,
                relatedIDs: base.relatedIDs
            ),
            MemoryRecord(
                id: "wrong-tag",
                namespace: base.namespace,
                scope: base.scope,
                category: base.category,
                summary: "Wrong tag",
                importance: base.importance,
                createdAt: now,
                tags: ["other-tag"],
                relatedIDs: base.relatedIDs
            ),
            MemoryRecord(
                id: "wrong-related-id",
                namespace: base.namespace,
                scope: base.scope,
                category: base.category,
                summary: "Wrong related id",
                importance: base.importance,
                createdAt: now,
                tags: base.tags,
                relatedIDs: ["other-id"]
            ),
            MemoryRecord(
                id: "low-importance",
                namespace: base.namespace,
                scope: base.scope,
                category: base.category,
                summary: "Low importance",
                importance: 0.1,
                createdAt: now,
                tags: base.tags,
                relatedIDs: base.relatedIDs
            ),
            MemoryRecord(
                id: "too-old",
                namespace: base.namespace,
                scope: base.scope,
                category: base.category,
                summary: "Too old",
                importance: base.importance,
                createdAt: now.addingTimeInterval(-7_200),
                tags: base.tags,
                relatedIDs: base.relatedIDs
            ),
        ])

        let result = try await store.query(MemoryQuery(
            namespace: base.namespace,
            scopes: [base.scope],
            categories: [base.category],
            tags: base.tags,
            relatedIDs: base.relatedIDs,
            recencyWindow: 3_600,
            minImportance: 0.5,
            limit: 10,
            maxCharacters: 1_000
        ))

        XCTAssertEqual(result.matches.map(\.record.id), [base.id])
        let materializedRecordCount = await store.materializedRecordCountForLatestQuery()
        XCTAssertEqual(materializedRecordCount, 1)
    }

    func testSQLiteMemoryRankingCursorSkipsOversizedRowsInsideSQLite() async throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMemoryStore(url: url)
        let timestamp = Date(timeIntervalSince1970: 100)
        let oversized = (0 ..< 20).map { index in
            MemoryRecord(
                id: String(format: "oversized-%02d", index),
                namespace: "assistant",
                scope: "project",
                category: "fact",
                summary: String(repeating: "oversized ", count: 40),
                importance: 0.8 - (Double(index) / 100),
                createdAt: timestamp
            )
        }
        let first = MemoryRecord(
            id: "first",
            namespace: "assistant",
            scope: "project",
            category: "fact",
            summary: "first ranked memory",
            importance: 1,
            createdAt: timestamp
        )
        let fitting = MemoryRecord(
            id: "fitting",
            namespace: "assistant",
            scope: "project",
            category: "fact",
            summary: "small",
            importance: 0.1,
            createdAt: timestamp
        )
        try await store.putMany([first] + oversized + [fitting])

        let firstPage = try await store.query(MemoryQuery(
            namespace: "assistant",
            limit: 1,
            maxCharacters: 10_000
        ))
        let cursor = try XCTUnwrap(firstPage.nextCursor)
        let nextPage = try await store.query(MemoryQuery(
            namespace: "assistant",
            limit: 1,
            maxCharacters: 100,
            cursor: cursor
        ))

        XCTAssertEqual(nextPage.matches.map(\.record.id), [fitting.id])
        let materializedRecordCount = await store.materializedRecordCountForLatestQuery()
        XCTAssertEqual(materializedRecordCount, 1)
    }

    func testSQLiteRanksAndLimitsLargeCandidateSetsBeforeMaterializingRecords() async throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMemoryStore(url: url)
        let timestamp = Date()
        let records = (0 ..< 250).map { index in
            MemoryRecord(
                id: String(format: "candidate-%03d", index),
                namespace: "assistant",
                scope: "project",
                category: "fact",
                summary: "shared database-ranked candidate",
                importance: Double(index) / 250,
                createdAt: timestamp
            )
        }
        try await store.putMany(records)

        let query = MemoryQuery(
            namespace: "assistant",
            scopes: ["project"],
            text: "shared database ranked",
            limit: 5,
            maxCharacters: 10_000
        )
        let result = try await store.query(query)

        XCTAssertEqual(result.matches.map(\.record.id), [
            "candidate-249",
            "candidate-248",
            "candidate-247",
            "candidate-246",
            "candidate-245",
        ])
        XCTAssertTrue(result.truncated)
        let materializedRecordCount = await store.materializedRecordCountForLatestQuery()
        XCTAssertEqual(materializedRecordCount, 5)

        let smallStoreSteps = try await store.rankedQueryVirtualMachineSteps(query)
        let additionalRecords = (250 ..< 10_000).map { index in
            MemoryRecord(
                id: String(format: "candidate-%05d", index),
                namespace: "assistant",
                scope: "project",
                category: "fact",
                summary: "shared database-ranked candidate",
                importance: Double(index % 1_000) / 1_000,
                createdAt: timestamp
            )
        }
        for start in stride(
            from: 0,
            to: additionalRecords.count,
            by: MemoryStoreLimits.maximumBulkRecordCount
        ) {
            let end = min(
                start + MemoryStoreLimits.maximumBulkRecordCount,
                additionalRecords.count
            )
            try await store.putMany(Array(additionalRecords[start ..< end]))
        }
        let largeStoreSteps = try await store.rankedQueryVirtualMachineSteps(query)
        XCTAssertLessThanOrEqual(
            largeStoreSteps,
            smallStoreSteps * 2,
            "The ranked query must stop after its bounded candidate window instead of scaling with 10,000 matches."
        )
    }

    func testSQLiteCharacterBudgetSkipsOversizedRowsWithoutMaterializingThem() async throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMemoryStore(url: url)
        try await store.putMany([
            MemoryRecord(
                id: "oversized",
                namespace: "assistant",
                scope: "project",
                category: "fact",
                summary: String(repeating: "x", count: 2_000),
                importance: 1
            ),
            MemoryRecord(
                id: "fits",
                namespace: "assistant",
                scope: "project",
                category: "fact",
                summary: "small result",
                importance: 0.5
            ),
        ])

        let result = try await store.query(MemoryQuery(
            namespace: "assistant",
            limit: 1,
            maxCharacters: 100
        ))

        XCTAssertEqual(result.matches.map(\.record.id), ["fits"])
        XCTAssertFalse(result.truncated)
        let materializedRecordCount = await store.materializedRecordCountForLatestQuery()
        XCTAssertEqual(materializedRecordCount, 1)
    }

    func testMemoryQueriesRejectNonFiniteThresholdsAndNegativeBudgets() async throws {
        let store = InMemoryMemoryStore()
        let nonFinite = MemoryQuery(namespace: "assistant", minImportance: .nan)
        await XCTAssertThrowsErrorAsync(try await store.query(nonFinite)) { error in
            XCTAssertEqual(
                error as? MemoryStoreError,
                .invalidQuery("minImportance must be between 0 and 1.")
            )
        }

        let negativeBudget = MemoryQuery(
            namespace: "assistant",
            limit: -1,
            maxCharacters: -1
        )
        await XCTAssertThrowsErrorAsync(try await store.query(negativeBudget)) { error in
            XCTAssertEqual(
                error as? MemoryStoreError,
                .invalidQuery("limit must be nonnegative.")
            )
        }

        let invalidTextPolicy = MemoryQuery(
            namespace: "assistant",
            text: "memory",
            textMatchPolicy: .atLeastTokens(0)
        )
        await XCTAssertThrowsErrorAsync(try await store.query(invalidTextPolicy)) { error in
            XCTAssertEqual(
                error as? MemoryStoreError,
                .invalidQuery("text matching must require at least one token.")
            )
        }

        let excessiveLimit = MemoryQuery(namespace: "assistant", limit: 257)
        await XCTAssertThrowsErrorAsync(try await store.query(excessiveLimit)) { error in
            XCTAssertEqual(
                error as? MemoryStoreError,
                .invalidQuery("limit must not exceed 256.")
            )
        }

        let excessiveFilters = MemoryQuery(
            namespace: "assistant",
            tags: (0 ..< 513).map { "tag-\($0)" }
        )
        await XCTAssertThrowsErrorAsync(try await store.query(excessiveFilters)) { error in
            XCTAssertEqual(
                error as? MemoryStoreError,
                .invalidQuery(
                    "combined scope, category, tag, and related-ID filters must not exceed 512 values."
                )
            )
        }

        let invalidCursor = MemoryQuery(
            namespace: "assistant",
            cursor: MemoryQueryCursor(
                namespace: "assistant",
                rankingProfile: .default,
                importance: 2,
                effectiveDate: Date(),
                recordOrder: 0,
                recordID: "record"
            )
        )
        await XCTAssertThrowsErrorAsync(try await store.query(invalidCursor)) { error in
            XCTAssertEqual(
                error as? MemoryStoreError,
                .invalidQuery("cursor does not match the query or contains invalid values.")
            )
        }

        await XCTAssertThrowsErrorAsync(try await store.list(
            MemoryRecordListQuery(namespace: "assistant", limit: -1)
        )) { error in
            XCTAssertEqual(
                error as? MemoryStoreError,
                .invalidQuery("list limit must be between 0 and 256.")
            )
        }
    }

    func testTextMatchPolicyUsesAnExactMinimumAndDecodesLegacyQueryDefault() async throws {
        let store = InMemoryMemoryStore(initialRecords: [
            MemoryRecord(
                id: "one-token",
                namespace: "assistant",
                scope: "project",
                category: "fact",
                summary: "memory"
            ),
        ])

        let strict = try await store.query(MemoryQuery(
            namespace: "assistant",
            text: "memory",
            textMatchPolicy: .atLeastTokens(2)
        ))
        XCTAssertTrue(strict.matches.isEmpty)

        let permissive = try await store.query(MemoryQuery(
            namespace: "assistant",
            text: "memory",
            textMatchPolicy: .anyToken
        ))
        XCTAssertEqual(permissive.matches.map(\.record.id), ["one-token"])

        let legacy = try JSONDecoder().decode(
            MemoryQuery.self,
            from: Data(#"{"namespace":"assistant"}"#.utf8)
        )
        XCTAssertEqual(legacy.textMatchPolicy, .anyToken)

        let configured = MemoryQuery(
            namespace: "assistant",
            textMatchPolicy: .atLeastTokens(3)
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                MemoryQuery.self,
                from: JSONEncoder().encode(configured)
            ).textMatchPolicy,
            .atLeastTokens(3)
        )
    }

    func testMemoryMatchExplanationDecodesLegacyWeightedPayload() throws {
        let payload = Data(#"{"totalScore":1,"textScore":1,"recencyScore":0,"importanceScore":0,"categoryBoost":0,"tagBoost":0,"relatedIDBoost":0}"#.utf8)
        let explanation = try JSONDecoder().decode(MemoryMatchExplanation.self, from: payload)
        XCTAssertEqual(explanation.executionMethod, .inMemory)
        XCTAssertEqual(explanation.matchedTokenCount, 1)
        XCTAssertEqual(explanation.queryTokenCount, 1)

        let legacyRealmPayload = Data(#"{"rankingMethod":"realmNativeTiered","totalScore":1,"textScore":1,"recencyScore":0,"importanceScore":0,"categoryBoost":0,"tagBoost":0,"relatedIDBoost":0}"#.utf8)
        let legacyRealmExplanation = try JSONDecoder().decode(
            MemoryMatchExplanation.self,
            from: legacyRealmPayload
        )
        XCTAssertEqual(legacyRealmExplanation.executionMethod, .databaseNative)

        let legacyDatabasePayload = Data(#"{"rankingMethod":"databaseNativeTiered","totalScore":1,"textScore":1,"recencyScore":0,"importanceScore":0,"categoryBoost":0,"tagBoost":0,"relatedIDBoost":0}"#.utf8)
        let legacyDatabaseExplanation = try JSONDecoder().decode(
            MemoryMatchExplanation.self,
            from: legacyDatabasePayload
        )
        XCTAssertEqual(legacyDatabaseExplanation.executionMethod, .databaseNative)
    }

    func testMemoryStoresRejectRecordsOutsideTheStructuredImportanceRule() async throws {
        let store = InMemoryMemoryStore()
        let invalid = MemoryRecord(
            namespace: "assistant",
            scope: "project",
            category: "fact",
            summary: "Invalid importance",
            importance: 1.1
        )

        await XCTAssertThrowsErrorAsync(try await store.put(invalid)) { error in
            XCTAssertEqual(
                error as? MemoryStoreError,
                .invalidRecord("importance must be finite and between 0 and 1.")
            )
        }
    }

    func testSQLiteSearchTokenPredicateAndPortableRankingExecuteBeforeTheResultLimit() async throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMemoryStore(url: url)
        let timestamp = Date()
        try await store.putMany([
            MemoryRecord(
                id: "strong-text",
                namespace: "assistant",
                scope: "project",
                category: "fact",
                summary: "brisk evening walk steps",
                importance: 0.1,
                createdAt: timestamp
            ),
            MemoryRecord(
                id: "weak-text",
                namespace: "assistant",
                scope: "project",
                category: "fact",
                summary: "evening status update",
                importance: 1,
                createdAt: timestamp
            ),
        ])

        let result = try await store.query(MemoryQuery(
            namespace: "assistant",
            text: "brisk evening walk steps",
            limit: 1,
            maxCharacters: 1_000
        ))

        XCTAssertEqual(result.matches.map(\.record.id), ["weak-text"])
        XCTAssertGreaterThan(result.matches[0].explanation.matchedTokenCount, 0)
        XCTAssertEqual(result.matches[0].explanation.executionMethod, .databaseNative)
        let materializedRecordCount = await store.materializedRecordCountForLatestQuery()
        XCTAssertEqual(materializedRecordCount, 1)
    }

    func testSQLiteSearchTokensTreatOperatorWordsAsSearchText() async throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMemoryStore(url: url)
        let record = MemoryRecord(
            id: "operator-word",
            namespace: "assistant",
            scope: "project",
            category: "fact",
            summary: "Choose this or that"
        )
        try await store.put(record)

        let result = try await store.query(MemoryQuery(
            namespace: "assistant",
            text: "OR",
            limit: 1,
            maxCharacters: 1_000
        ))

        XCTAssertEqual(result.matches.map(\.record.id), [record.id])
        XCTAssertGreaterThan(result.matches[0].explanation.matchedTokenCount, 0)
    }

    func testSQLiteImportanceProfileBoundsPackingAfterCompositeIndexScan() async throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMemoryStore(url: url)
        try await store.prepare()

        let details = try await store.rankedQueryPlan(MemoryQuery(
            namespace: "assistant",
            limit: 8,
            maxCharacters: 4_096
        ))
        let plan = details.joined(separator: "\n")
        let indexSearch = try XCTUnwrap(details.firstIndex {
            $0.contains("memory_records_active_importance_recency")
        })
        let firstTemporarySort = try XCTUnwrap(details.firstIndex {
            $0.contains("USE TEMP B-TREE")
        })
        XCTAssertTrue(plan.contains("MATERIALIZE candidate_window"), plan)
        XCTAssertTrue(plan.contains("memory_records_active_importance_recency"), plan)
        XCTAssertGreaterThan(firstTemporarySort, indexSearch, plan)
        XCTAssertFalse(details.contains { $0 == "SCAN r" }, plan)
    }

    func testSQLiteIncludeArchivedRankingBoundsPackingAfterCompositeIndexScan() async throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMemoryStore(url: url)
        try await store.prepare()

        let details = try await store.rankedQueryPlan(MemoryQuery(
            namespace: "assistant",
            limit: 8,
            maxCharacters: 4_096,
            includeArchived: true
        ))
        let plan = details.joined(separator: "\n")
        let indexSearch = try XCTUnwrap(details.firstIndex {
            $0.contains("memory_records_importance_recency")
        })
        let firstTemporarySort = try XCTUnwrap(details.firstIndex {
            $0.contains("USE TEMP B-TREE")
        })
        XCTAssertTrue(plan.contains("MATERIALIZE candidate_window"), plan)
        XCTAssertTrue(plan.contains("memory_records_importance_recency"), plan)
        XCTAssertGreaterThan(firstTemporarySort, indexSearch, plan)
        XCTAssertFalse(details.contains { $0 == "SCAN r" }, plan)
    }

    func testSQLiteDiagnosticsSnapshotTracksEveryMutationPath() async throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMemoryStore(url: url)

        try await store.putMany([
            MemoryRecord(
                id: "first",
                namespace: "assistant",
                scope: "project",
                category: "fact",
                summary: "first",
                dedupeKey: "replace-me"
            ),
            MemoryRecord(
                id: "second",
                namespace: "assistant",
                scope: "thread",
                category: "preference",
                summary: "second"
            ),
        ])
        try await store.archive(ids: ["second"], namespace: "assistant")
        try await store.upsert(
            MemoryRecord(
                id: "replacement",
                namespace: "assistant",
                scope: "user",
                category: "summary",
                summary: "replacement"
            ),
            dedupeKey: "replace-me"
        )

        var diagnostics = try await store.diagnostics(namespace: "assistant")
        XCTAssertEqual(diagnostics.totalRecords, 2)
        XCTAssertEqual(diagnostics.activeRecords, 1)
        XCTAssertEqual(diagnostics.archivedRecords, 1)
        XCTAssertEqual(diagnostics.countsByScope, ["thread": 1, "user": 1])
        XCTAssertEqual(diagnostics.countsByCategory, ["preference": 1, "summary": 1])

        try await store.delete(ids: ["second"], namespace: "assistant")
        let now = Date()
        try await store.put(MemoryRecord(
            id: "expired",
            namespace: "assistant",
            scope: "thread",
            category: "transient",
            summary: "expired",
            expiresAt: now.addingTimeInterval(-1)
        ))
        let prunedCount = try await store.pruneExpired(now: now, namespace: "assistant")
        XCTAssertEqual(prunedCount, 1)

        diagnostics = try await store.diagnostics(namespace: "assistant")
        XCTAssertEqual(diagnostics.totalRecords, 1)
        XCTAssertEqual(diagnostics.activeRecords, 1)
        XCTAssertEqual(diagnostics.archivedRecords, 0)
        XCTAssertEqual(diagnostics.countsByScope, ["user": 1])
        XCTAssertEqual(diagnostics.countsByCategory, ["summary": 1])

        try await store.delete(ids: ["replacement"], namespace: "assistant")
        diagnostics = try await store.diagnostics(namespace: "assistant")
        XCTAssertEqual(diagnostics.totalRecords, 0)
        XCTAssertEqual(diagnostics.countsByScope, [:])
        XCTAssertEqual(diagnostics.countsByCategory, [:])
    }

    func testSQLiteConcurrentPrunesReportOnlyRowsDeletedByTheirTransaction() async throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let firstStore = try SQLiteMemoryStore(url: url)
        let secondStore = try SQLiteMemoryStore(url: url)
        let now = Date()
        try await firstStore.putMany((0 ..< 100).map { index in
            MemoryRecord(
                id: "expired-\(index)",
                namespace: "assistant",
                scope: "thread",
                category: "transient",
                summary: "expired",
                expiresAt: now.addingTimeInterval(-1)
            )
        })

        async let firstCount = firstStore.pruneExpired(now: now, namespace: "assistant")
        async let secondCount = secondStore.pruneExpired(now: now, namespace: "assistant")
        let deletedCounts = try await [firstCount, secondCount]

        XCTAssertEqual(deletedCounts.reduce(0, +), 100)
        let remaining = try await firstStore.list(namespace: "assistant")
        XCTAssertEqual(remaining, [])
    }

    func testMemoryMigrationDoesNotCommitAnEarlierNamespaceWhenALaterRecordIsInvalid() async throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let destination = try SQLiteMemoryStore(url: url)
        let source = MigrationSourceMemoryStore(records: [
            MemoryRecord(
                id: "valid",
                namespace: "a-valid",
                scope: "project",
                category: "fact",
                summary: "valid"
            ),
            MemoryRecord(
                id: "invalid",
                namespace: "z-invalid",
                scope: "project",
                category: "fact",
                summary: "invalid",
                importance: 2
            ),
        ])

        await XCTAssertThrowsErrorAsync(try await MemoryStoreMigrator.migrate(
            namespaces: ["a-valid", "z-invalid"],
            from: source,
            to: destination
        ))

        let committed = try await destination.list(
            namespace: "a-valid",
            includeArchived: true
        )
        XCTAssertTrue(committed.isEmpty)
    }

    func testSQLiteTextPredicateKeepsNativeOrderIndexAndUsesTokenLookupIndex() async throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteMemoryStore(url: url)
        try await store.prepare()

        let details = try await store.rankedQueryPlan(MemoryQuery(
            namespace: "assistant",
            text: "shared memory",
            textMatchPolicy: .allTokens,
            limit: 8,
            maxCharacters: 4_096
        ))
        let plan = details.joined(separator: "\n")
        XCTAssertTrue(plan.contains("MATERIALIZE candidate_window"), plan)
        XCTAssertTrue(plan.contains("memory_records_active_importance_recency"), plan)
        XCTAssertTrue(
            plan.contains("SEARCH mst USING COVERING INDEX") &&
                plan.contains("memory_search_tokens"),
            plan
        )
        XCTAssertFalse(plan.contains("SCAN memory_search_tokens"), plan)
    }

    func testRankingProfileDecodesLegacyWeights() throws {
        let importancePayload = Data(
            #"{"importanceWeight":0.8,"recencyWeight":0.2,"textWeight":1,"categoryBoost":1,"tagBoost":1,"relatedIDBoost":1}"#.utf8
        )
        let recencyPayload = Data(
            #"{"importanceWeight":0.1,"recencyWeight":0.9,"textWeight":1,"categoryBoost":1,"tagBoost":1,"relatedIDBoost":1}"#.utf8
        )
        XCTAssertEqual(
            try JSONDecoder().decode(MemoryRankingProfile.self, from: importancePayload),
            .importanceThenRecency
        )
        XCTAssertEqual(
            try JSONDecoder().decode(MemoryRankingProfile.self, from: recencyPayload),
            .recencyThenImportance
        )
    }

    func testSQLiteStoreRejectsUnsupportedFutureSchemaVersion() async throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }

        var database: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(
                url.path,
                &database,
                SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
                nil
            ),
            SQLITE_OK
        )
        XCTAssertEqual(sqlite3_exec(database, "PRAGMA user_version = 999;", nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)

        let store = try SQLiteMemoryStore(url: url)
        await XCTAssertThrowsErrorAsync(try await store.prepare()) { error in
            XCTAssertEqual(
                error as? MemoryStoreError,
                .unsupportedSchemaVersion(999)
            )
        }
    }

    func testPutManyIsAtomicWhenDuplicateIDIsPresent() async throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try SQLiteMemoryStore(url: url)
        let existing = MemoryRecord(
            id: "memory-1",
            namespace: "demo-assistant",
            scope: "feature:health-coach",
            category: "fact",
            summary: "Existing memory."
        )
        try await store.put(existing)

        await XCTAssertThrowsErrorAsync(
            try await store.putMany([
                MemoryRecord(
                    id: "memory-2",
                    namespace: "demo-assistant",
                    scope: "feature:health-coach",
                    category: "fact",
                    summary: "Should roll back."
                ),
                MemoryRecord(
                    id: "memory-1",
                    namespace: "demo-assistant",
                    scope: "feature:travel-planner",
                    category: "fact",
                    summary: "Duplicate id."
                ),
            ])
        ) { error in
            XCTAssertEqual(
                error as? MemoryStoreError,
                .duplicateRecordID("memory-1")
            )
        }

        let result = try await store.query(
            MemoryQuery(
                namespace: "demo-assistant",
                scopes: [],
                limit: 10,
                maxCharacters: 1000
            )
        )
        XCTAssertEqual(result.matches.map(\.record.id), ["memory-1"])
    }

    func testUpsertIsRetrySafeByDedupeKey() async throws {
        let store = InMemoryMemoryStore()

        try await store.upsert(
            MemoryRecord(
                id: "memory-1",
                namespace: "demo-assistant",
                scope: "feature:travel-planner",
                category: "quote_record",
                summary: "Initial itinerary note."
            ),
            dedupeKey: "travel-plan-17"
        )

        try await store.upsert(
            MemoryRecord(
                id: "memory-2",
                namespace: "demo-assistant",
                scope: "feature:travel-planner",
                category: "quote_record",
                summary: "Updated itinerary note after retry."
            ),
            dedupeKey: "travel-plan-17"
        )

        let result = try await store.query(
            MemoryQuery(
                namespace: "demo-assistant",
                scopes: ["feature:travel-planner"],
                limit: 10,
                maxCharacters: 1000
            )
        )

        XCTAssertEqual(result.matches.count, 1)
        XCTAssertEqual(result.matches[0].record.id, "memory-2")
        XCTAssertEqual(result.matches[0].record.dedupeKey, "travel-plan-17")
    }

    func testMemoryWriterAppliesDefaultsAndUpsertsDraft() async throws {
        let store = InMemoryMemoryStore()
        let writer = MemoryWriter(
            store: store,
            defaults: MemoryWriterDefaults(
                namespace: "demo-assistant",
                scope: "feature:health-coach",
                category: "preference",
                importance: 0.6,
                tags: ["demo", "health"],
                relatedIDs: ["goal-10000"]
            )
        )

        let record = try await writer.upsert(
            MemoryDraft(
                summary: "Use direct accountability when the user is behind on steps.",
                evidence: ["The user follows through more often with blunt reminders."],
                importance: 0.95,
                tags: ["tone"],
                dedupeKey: "health-coach-direct-tone"
            )
        )

        XCTAssertEqual(record.namespace, "demo-assistant")
        XCTAssertEqual(record.scope, "feature:health-coach")
        XCTAssertEqual(record.category, "preference")
        XCTAssertEqual(record.tags, ["demo", "health", "tone"])
        XCTAssertEqual(record.relatedIDs, ["goal-10000"])
        XCTAssertEqual(record.dedupeKey, "health-coach-direct-tone")

        let result = try await store.query(
            MemoryQuery(
                namespace: "demo-assistant",
                scopes: ["feature:health-coach"],
                text: "direct steps accountability",
                limit: 10,
                maxCharacters: 1000
            )
        )
        XCTAssertEqual(result.matches.map(\.record.id), [record.id])
    }

    func testMemoryWriterThrowsWhenRequiredDefaultsAreMissing() async throws {
        let writer = MemoryWriter(store: InMemoryMemoryStore())

        do {
            _ = try await writer.resolve(
                MemoryDraft(summary: "Missing namespace and scope.")
            )
            XCTFail("Expected missing namespace error.")
        } catch {
            XCTAssertEqual(error as? MemoryAuthoringError, .missingNamespace)
        }

        let namespaceOnlyWriter = MemoryWriter(
            store: InMemoryMemoryStore(),
            defaults: MemoryWriterDefaults(namespace: "demo-assistant")
        )

        do {
            _ = try await namespaceOnlyWriter.resolve(
                MemoryDraft(summary: "Still missing scope.")
            )
            XCTFail("Expected missing scope error.")
        } catch {
            XCTAssertEqual(error as? MemoryAuthoringError, .missingScope)
        }
    }

    func testStoreInspectionAPIsReturnRecordsAndDiagnostics() async throws {
        let store = InMemoryMemoryStore()
        try await store.putMany([
            MemoryRecord(
                id: "active-memory",
                namespace: "demo-assistant",
                scope: "feature:health-coach",
                category: "preference",
                summary: "Active memory."
            ),
            MemoryRecord(
                id: "archived-memory",
                namespace: "demo-assistant",
                scope: "feature:travel-planner",
                category: "summary",
                summary: "Archived memory.",
                status: .archived
            ),
        ])

        let fetched = try await store.record(
            id: "active-memory",
            namespace: "demo-assistant"
        )
        XCTAssertEqual(fetched?.category, "preference")

        let listed = try await store.list(
            namespace: "demo-assistant",
            includeArchived: true,
            limit: 10
        )
        XCTAssertEqual(listed.map(\.id).sorted(), ["active-memory", "archived-memory"])

        let diagnostics = try await store.diagnostics(namespace: "demo-assistant")
        XCTAssertEqual(diagnostics.implementation, .inMemory)
        XCTAssertNil(diagnostics.schemaVersion)
        XCTAssertEqual(diagnostics.totalRecords, 2)
        XCTAssertEqual(diagnostics.activeRecords, 1)
        XCTAssertEqual(diagnostics.archivedRecords, 1)
        XCTAssertEqual(diagnostics.countsByScope["feature:health-coach"], 1)
        XCTAssertEqual(diagnostics.countsByCategory["summary"], 1)
    }

    func testQueryFiltersRanksAndPacksTheAggregateBudget() async throws {
        let store = InMemoryMemoryStore()
        try await store.putMany([
            MemoryRecord(
                id: "match-1",
                namespace: "demo-assistant",
                scope: "feature:health-coach",
                category: "preference",
                summary: "Health Coach should push for a 15 minute walk when step pace is low.",
                evidence: ["The user follows through when told to walk before dinner."],
                importance: 0.95,
                tags: ["steps", "walk"],
                relatedIDs: ["goal-10000"]
            ),
            MemoryRecord(
                id: "match-2",
                namespace: "demo-assistant",
                scope: "feature:health-coach",
                category: "preference",
                summary: "A second long coaching note that should be trimmed by the budget.",
                evidence: ["This extra line makes the rendered memory longer than the cap."],
                importance: 0.80,
                tags: ["steps"],
                relatedIDs: ["goal-10000"]
            ),
            MemoryRecord(
                id: "other-scope",
                namespace: "demo-assistant",
                scope: "feature:travel-planner",
                category: "preference",
                summary: "Travel Planner prefers early museum starts.",
                importance: 0.99,
                tags: ["steps"],
                relatedIDs: ["goal-10000"]
            ),
        ])

        let result = try await store.query(
            MemoryQuery(
                namespace: "demo-assistant",
                scopes: ["feature:health-coach"],
                text: "steps walk dinner",
                categories: ["preference"],
                tags: ["steps"],
                relatedIDs: ["goal-10000"],
                minImportance: 0.5,
                limit: 10,
                maxCharacters: 220
            )
        )

        XCTAssertEqual(result.matches.map(\.record.id), ["match-1"])
        XCTAssertTrue(result.truncated)
        let rendered = MemoryQueryEngine.renderPrompt(
            matches: result.matches,
            budget: MemoryReadBudget(maxItems: 10, maxCharacters: 220)
        )
        XCTAssertTrue(rendered.contains("15 minute walk"))
        XCTAssertFalse(rendered.contains("second long coaching note"))
        XCTAssertLessThanOrEqual(rendered.count, 220)
    }

    func testInMemoryQueryUsesTextAsPredicateAndPortableProfileForOrdering() async throws {
        let store = InMemoryMemoryStore()
        try await store.putMany([
            MemoryRecord(
                id: "strong-match",
                namespace: "demo-assistant",
                scope: "feature:health-coach",
                category: "fact",
                summary: "Health Coach should ask for a brisk evening walk when steps are low.",
                importance: 0.1
            ),
            MemoryRecord(
                id: "weak-match",
                namespace: "demo-assistant",
                scope: "feature:health-coach",
                category: "fact",
                summary: "Health Coach checked in about a walk today.",
                importance: 0.9
            ),
        ])

        let result = try await store.query(
            MemoryQuery(
                namespace: "demo-assistant",
                scopes: ["feature:health-coach"],
                text: "brisk walk steps",
                limit: 10,
                maxCharacters: 1000
            )
        )

        XCTAssertEqual(result.matches.map(\.record.id), ["weak-match", "strong-match"])
    }

    func testQuerySkipsOversizedTopCandidateAndKeepsSmallerMatch() async throws {
        let store = InMemoryMemoryStore()
        let oversizedSummary = String(repeating: "step ", count: 80)

        try await store.putMany([
            MemoryRecord(
                id: "oversized",
                namespace: "demo-assistant",
                scope: "feature:health-coach",
                category: "fact",
                summary: oversizedSummary,
                importance: 1.0
            ),
            MemoryRecord(
                id: "fits-budget",
                namespace: "demo-assistant",
                scope: "feature:health-coach",
                category: "fact",
                summary: "Short step reminder for Health Coach.",
                importance: 0.2
            ),
        ])

        let result = try await store.query(
            MemoryQuery(
                namespace: "demo-assistant",
                scopes: ["feature:health-coach"],
                text: "step",
                limit: 10,
                maxCharacters: 120
            )
        )

        XCTAssertEqual(result.matches.map(\.record.id), ["fits-budget"])
        XCTAssertFalse(result.truncated)
    }

    func testCompactArchivesSourcesAndPruneExpiredSkipsPinned() async throws {
        let store = InMemoryMemoryStore()
        let now = Date()

        try await store.putMany([
            MemoryRecord(
                id: "source-1",
                namespace: "demo-assistant",
                scope: "feature:health-coach",
                category: "fact",
                summary: "Source memory one."
            ),
            MemoryRecord(
                id: "source-2",
                namespace: "demo-assistant",
                scope: "feature:health-coach",
                category: "fact",
                summary: "Source memory two."
            ),
            MemoryRecord(
                id: "expired-pinned",
                namespace: "demo-assistant",
                scope: "feature:travel-planner",
                category: "summary",
                summary: "Pinned memory should survive pruning.",
                expiresAt: now.addingTimeInterval(-60),
                isPinned: true
            ),
            MemoryRecord(
                id: "expired-unpinned",
                namespace: "demo-assistant",
                scope: "feature:travel-planner",
                category: "summary",
                summary: "Unpinned memory should be removed.",
                expiresAt: now.addingTimeInterval(-60)
            ),
        ])

        try await store.compact(
            MemoryCompactionRequest(
                replacement: MemoryRecord(
                    id: "replacement",
                    namespace: "demo-assistant",
                    scope: "feature:health-coach",
                    category: "summary",
                    summary: "Compacted health coach summary."
                ),
                sourceIDs: ["source-1", "source-2"]
            )
        )

        let active = try await store.query(
            MemoryQuery(
                namespace: "demo-assistant",
                scopes: ["feature:health-coach"],
                limit: 10,
                maxCharacters: 1000
            )
        )
        XCTAssertEqual(active.matches.map(\.record.id), ["replacement"])

        let prunedCount = try await store.pruneExpired(
            now: now,
            namespace: "demo-assistant"
        )
        XCTAssertEqual(prunedCount, 1)

        let remaining = try await store.query(
            MemoryQuery(
                namespace: "demo-assistant",
                scopes: ["feature:travel-planner"],
                limit: 10,
                maxCharacters: 1000
            )
        )
        XCTAssertEqual(remaining.matches.map(\.record.id), ["expired-pinned"])
    }

    private func temporarySQLiteURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
    }
}

private enum MigrationSourceMemoryStoreError: Error {
    case unsupported
}

private actor MigrationSourceMemoryStore: MemoryStoring {
    let records: [MemoryRecord]

    init(records: [MemoryRecord]) {
        self.records = records
    }

    func put(_ record: MemoryRecord) async throws { throw MigrationSourceMemoryStoreError.unsupported }
    func putMany(_ records: [MemoryRecord]) async throws { throw MigrationSourceMemoryStoreError.unsupported }
    func upsert(_ record: MemoryRecord, dedupeKey: String) async throws {
        throw MigrationSourceMemoryStoreError.unsupported
    }
    func query(_ query: MemoryQuery) async throws -> MemoryQueryResult {
        throw MigrationSourceMemoryStoreError.unsupported
    }
    func record(id: String, namespace: String) async throws -> MemoryRecord? {
        records.first { $0.id == id && $0.namespace == namespace }
    }
    func list(_ query: MemoryRecordListQuery) async throws -> [MemoryRecord] {
        records.filter { $0.namespace == query.namespace }
    }
    func diagnostics(namespace: String) async throws -> MemoryStoreDiagnostics {
        throw MigrationSourceMemoryStoreError.unsupported
    }
    func compact(_ request: MemoryCompactionRequest) async throws {
        throw MigrationSourceMemoryStoreError.unsupported
    }
    func archive(ids: [String], namespace: String) async throws {
        throw MigrationSourceMemoryStoreError.unsupported
    }
    func delete(ids: [String], namespace: String) async throws {
        throw MigrationSourceMemoryStoreError.unsupported
    }
    func pruneExpired(now: Date, namespace: String) async throws -> Int {
        throw MigrationSourceMemoryStoreError.unsupported
    }
}
