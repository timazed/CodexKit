import CodexKit
import Foundation
import SQLite3
import XCTest

final class MemoryStoreTests: XCTestCase {
    func testSQLiteStorePersistsAndReloadsRecords() async throws {
        let url = temporarySQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try SQLiteMemoryStore(url: url)
        let record = MemoryRecord(
            namespace: "demo-assistant",
            scope: "feature:health-coach",
            kind: "preference",
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
        XCTAssertGreaterThan(result.matches[0].explanation.textScore, 0)

        let diagnostics = try await reloaded.diagnostics(namespace: "demo-assistant")
        XCTAssertEqual(diagnostics.implementation, "sqlite")
        XCTAssertEqual(diagnostics.schemaVersion, 1)
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

        XCTAssertThrowsError(try SQLiteMemoryStore(url: url)) { error in
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
            kind: "fact",
            summary: "Existing memory."
        )
        try await store.put(existing)

        await XCTAssertThrowsErrorAsync(
            try await store.putMany([
                MemoryRecord(
                    id: "memory-2",
                    namespace: "demo-assistant",
                    scope: "feature:health-coach",
                    kind: "fact",
                    summary: "Should roll back."
                ),
                MemoryRecord(
                    id: "memory-1",
                    namespace: "demo-assistant",
                    scope: "feature:travel-planner",
                    kind: "fact",
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
                kind: "quote_record",
                summary: "Initial itinerary note."
            ),
            dedupeKey: "travel-plan-17"
        )

        try await store.upsert(
            MemoryRecord(
                id: "memory-2",
                namespace: "demo-assistant",
                scope: "feature:travel-planner",
                kind: "quote_record",
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
                kind: "preference",
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
        XCTAssertEqual(record.kind, "preference")
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

        XCTAssertThrowsError(
            try writer.resolve(
                MemoryDraft(summary: "Missing namespace and scope.")
            )
        ) { error in
            XCTAssertEqual(error as? MemoryAuthoringError, .missingNamespace)
        }

        let namespaceOnlyWriter = MemoryWriter(
            store: InMemoryMemoryStore(),
            defaults: MemoryWriterDefaults(namespace: "demo-assistant")
        )

        XCTAssertThrowsError(
            try namespaceOnlyWriter.resolve(
                MemoryDraft(summary: "Still missing scope.")
            )
        ) { error in
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
                kind: "preference",
                summary: "Active memory."
            ),
            MemoryRecord(
                id: "archived-memory",
                namespace: "demo-assistant",
                scope: "feature:travel-planner",
                kind: "summary",
                summary: "Archived memory.",
                status: .archived
            ),
        ])

        let fetched = try await store.record(
            id: "active-memory",
            namespace: "demo-assistant"
        )
        XCTAssertEqual(fetched?.kind, "preference")

        let listed = try await store.list(
            namespace: "demo-assistant",
            includeArchived: true,
            limit: 10
        )
        XCTAssertEqual(listed.map(\.id).sorted(), ["active-memory", "archived-memory"])

        let diagnostics = try await store.diagnostics(namespace: "demo-assistant")
        XCTAssertEqual(diagnostics.implementation, "in_memory")
        XCTAssertNil(diagnostics.schemaVersion)
        XCTAssertEqual(diagnostics.totalRecords, 2)
        XCTAssertEqual(diagnostics.activeRecords, 1)
        XCTAssertEqual(diagnostics.archivedRecords, 1)
        XCTAssertEqual(diagnostics.countsByScope["feature:health-coach"], 1)
        XCTAssertEqual(diagnostics.countsByKind["summary"], 1)
    }

    func testQueryFiltersRankingAndCharacterBudget() async throws {
        let store = InMemoryMemoryStore()
        try await store.putMany([
            MemoryRecord(
                id: "match-1",
                namespace: "demo-assistant",
                scope: "feature:health-coach",
                kind: "preference",
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
                kind: "preference",
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
                kind: "preference",
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
                kinds: ["preference"],
                tags: ["steps"],
                relatedIDs: ["goal-10000"],
                minImportance: 0.5,
                limit: 10,
                maxCharacters: 220
            )
        )

        XCTAssertEqual(result.matches.count, 1)
        XCTAssertEqual(result.matches.map(\.record.id), ["match-1"])
        XCTAssertTrue(result.truncated)
        XCTAssertGreaterThan(result.matches[0].explanation.kindBoost, 0)
        XCTAssertGreaterThan(result.matches[0].explanation.tagBoost, 0)
        XCTAssertGreaterThan(result.matches[0].explanation.relatedIDBoost, 0)
    }

    func testInMemoryQueryPrefersHigherTextOverlap() async throws {
        let store = InMemoryMemoryStore()
        try await store.putMany([
            MemoryRecord(
                id: "strong-match",
                namespace: "demo-assistant",
                scope: "feature:health-coach",
                kind: "fact",
                summary: "Health Coach should ask for a brisk evening walk when steps are low."
            ),
            MemoryRecord(
                id: "weak-match",
                namespace: "demo-assistant",
                scope: "feature:health-coach",
                kind: "fact",
                summary: "Health Coach checked in with the user today."
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

        XCTAssertEqual(result.matches.first?.record.id, "strong-match")
        XCTAssertGreaterThan(
            result.matches.first?.explanation.textScore ?? 0,
            result.matches.dropFirst().first?.explanation.textScore ?? 0
        )
    }

    func testQuerySkipsOversizedTopCandidateAndKeepsSmallerMatch() async throws {
        let store = InMemoryMemoryStore()
        let oversizedSummary = String(repeating: "trade ", count: 80)

        try await store.putMany([
            MemoryRecord(
                id: "oversized",
                namespace: "demo-assistant",
                scope: "feature:health-coach",
                kind: "fact",
                summary: oversizedSummary,
                importance: 1.0
            ),
            MemoryRecord(
                id: "fits-budget",
                namespace: "demo-assistant",
                scope: "feature:health-coach",
                kind: "fact",
                summary: "Short step reminder for Health Coach.",
                importance: 0.2
            ),
        ])

        let result = try await store.query(
            MemoryQuery(
                namespace: "demo-assistant",
                scopes: ["feature:health-coach"],
                text: "steps",
                limit: 10,
                maxCharacters: 120
            )
        )

        XCTAssertEqual(result.matches.map(\.record.id), ["fits-budget"])
        XCTAssertTrue(result.truncated)
    }

    func testCompactArchivesSourcesAndPruneExpiredSkipsPinned() async throws {
        let store = InMemoryMemoryStore()
        let now = Date()

        try await store.putMany([
            MemoryRecord(
                id: "source-1",
                namespace: "demo-assistant",
                scope: "feature:health-coach",
                kind: "fact",
                summary: "Source memory one."
            ),
            MemoryRecord(
                id: "source-2",
                namespace: "demo-assistant",
                scope: "feature:health-coach",
                kind: "fact",
                summary: "Source memory two."
            ),
            MemoryRecord(
                id: "expired-pinned",
                namespace: "demo-assistant",
                scope: "feature:travel-planner",
                kind: "summary",
                summary: "Pinned memory should survive pruning.",
                expiresAt: now.addingTimeInterval(-60),
                isPinned: true
            ),
            MemoryRecord(
                id: "expired-unpinned",
                namespace: "demo-assistant",
                scope: "feature:travel-planner",
                kind: "summary",
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
                    kind: "summary",
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
