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
            namespace: "oval-office",
            scope: "actor:eleanor_price",
            kind: "grievance",
            summary: "Eleanor remembers being overruled on the trade bill.",
            evidence: ["The player dismissed her warning on day 12."],
            importance: 0.9,
            tags: ["trade", "advisors"],
            relatedIDs: ["bill-12"],
            dedupeKey: "eleanor-trade-day-12"
        )

        try await store.put(record)

        let reloaded = try SQLiteMemoryStore(url: url)
        let result = try await reloaded.query(
            MemoryQuery(
                namespace: "oval-office",
                scopes: ["actor:eleanor_price"],
                text: "overruled trade warning",
                limit: 5,
                maxCharacters: 600
            )
        )

        XCTAssertEqual(result.matches.map(\.record.id), [record.id])
        XCTAssertGreaterThan(result.matches[0].explanation.textScore, 0)

        let diagnostics = try await reloaded.diagnostics(namespace: "oval-office")
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
            namespace: "oval-office",
            scope: "actor:eleanor_price",
            kind: "fact",
            summary: "Existing memory."
        )
        try await store.put(existing)

        await XCTAssertThrowsErrorAsync(
            try await store.putMany([
                MemoryRecord(
                    id: "memory-2",
                    namespace: "oval-office",
                    scope: "actor:eleanor_price",
                    kind: "fact",
                    summary: "Should roll back."
                ),
                MemoryRecord(
                    id: "memory-1",
                    namespace: "oval-office",
                    scope: "actor:sophia_ramirez",
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
                namespace: "oval-office",
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
                namespace: "oval-office",
                scope: "actor:eleanor_price",
                kind: "quote_record",
                summary: "Initial quote."
            ),
            dedupeKey: "press-quote-17"
        )

        try await store.upsert(
            MemoryRecord(
                id: "memory-2",
                namespace: "oval-office",
                scope: "actor:eleanor_price",
                kind: "quote_record",
                summary: "Updated quote after retry."
            ),
            dedupeKey: "press-quote-17"
        )

        let result = try await store.query(
            MemoryQuery(
                namespace: "oval-office",
                scopes: ["actor:eleanor_price"],
                limit: 10,
                maxCharacters: 1000
            )
        )

        XCTAssertEqual(result.matches.count, 1)
        XCTAssertEqual(result.matches[0].record.id, "memory-2")
        XCTAssertEqual(result.matches[0].record.dedupeKey, "press-quote-17")
    }

    func testStoreInspectionAPIsReturnRecordsAndDiagnostics() async throws {
        let store = InMemoryMemoryStore()
        try await store.putMany([
            MemoryRecord(
                id: "active-memory",
                namespace: "oval-office",
                scope: "actor:eleanor_price",
                kind: "grievance",
                summary: "Active memory."
            ),
            MemoryRecord(
                id: "archived-memory",
                namespace: "oval-office",
                scope: "world:press",
                kind: "summary",
                summary: "Archived memory.",
                status: .archived
            ),
        ])

        let fetched = try await store.record(
            id: "active-memory",
            namespace: "oval-office"
        )
        XCTAssertEqual(fetched?.kind, "grievance")

        let listed = try await store.list(
            namespace: "oval-office",
            includeArchived: true,
            limit: 10
        )
        XCTAssertEqual(listed.map(\.id).sorted(), ["active-memory", "archived-memory"])

        let diagnostics = try await store.diagnostics(namespace: "oval-office")
        XCTAssertEqual(diagnostics.implementation, "in_memory")
        XCTAssertNil(diagnostics.schemaVersion)
        XCTAssertEqual(diagnostics.totalRecords, 2)
        XCTAssertEqual(diagnostics.activeRecords, 1)
        XCTAssertEqual(diagnostics.archivedRecords, 1)
        XCTAssertEqual(diagnostics.countsByScope["actor:eleanor_price"], 1)
        XCTAssertEqual(diagnostics.countsByKind["summary"], 1)
    }

    func testQueryFiltersRankingAndCharacterBudget() async throws {
        let store = InMemoryMemoryStore()
        try await store.putMany([
            MemoryRecord(
                id: "match-1",
                namespace: "oval-office",
                scope: "actor:eleanor_price",
                kind: "grievance",
                summary: "Eleanor is still angry about the farm subsidy reversal.",
                evidence: ["She warned the player twice before being ignored."],
                importance: 0.95,
                tags: ["farm", "economy"],
                relatedIDs: ["policy-farm"]
            ),
            MemoryRecord(
                id: "match-2",
                namespace: "oval-office",
                scope: "actor:eleanor_price",
                kind: "grievance",
                summary: "A second long grievance that should be trimmed by the budget.",
                evidence: ["This extra line makes the rendered memory longer than the cap."],
                importance: 0.80,
                tags: ["farm"],
                relatedIDs: ["policy-farm"]
            ),
            MemoryRecord(
                id: "other-scope",
                namespace: "oval-office",
                scope: "actor:sophia_ramirez",
                kind: "grievance",
                summary: "Sophia has a separate grievance.",
                importance: 0.99,
                tags: ["farm"],
                relatedIDs: ["policy-farm"]
            ),
        ])

        let result = try await store.query(
            MemoryQuery(
                namespace: "oval-office",
                scopes: ["actor:eleanor_price"],
                text: "farm grievance warning",
                kinds: ["grievance"],
                tags: ["farm"],
                relatedIDs: ["policy-farm"],
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

    func testCompactArchivesSourcesAndPruneExpiredSkipsPinned() async throws {
        let store = InMemoryMemoryStore()
        let now = Date()

        try await store.putMany([
            MemoryRecord(
                id: "source-1",
                namespace: "oval-office",
                scope: "actor:eleanor_price",
                kind: "fact",
                summary: "Source memory one."
            ),
            MemoryRecord(
                id: "source-2",
                namespace: "oval-office",
                scope: "actor:eleanor_price",
                kind: "fact",
                summary: "Source memory two."
            ),
            MemoryRecord(
                id: "expired-pinned",
                namespace: "oval-office",
                scope: "world:press",
                kind: "summary",
                summary: "Pinned memory should survive pruning.",
                expiresAt: now.addingTimeInterval(-60),
                isPinned: true
            ),
            MemoryRecord(
                id: "expired-unpinned",
                namespace: "oval-office",
                scope: "world:press",
                kind: "summary",
                summary: "Unpinned memory should be removed.",
                expiresAt: now.addingTimeInterval(-60)
            ),
        ])

        try await store.compact(
            MemoryCompactionRequest(
                replacement: MemoryRecord(
                    id: "replacement",
                    namespace: "oval-office",
                    scope: "actor:eleanor_price",
                    kind: "summary",
                    summary: "Compacted grievance summary."
                ),
                sourceIDs: ["source-1", "source-2"]
            )
        )

        let active = try await store.query(
            MemoryQuery(
                namespace: "oval-office",
                scopes: ["actor:eleanor_price"],
                limit: 10,
                maxCharacters: 1000
            )
        )
        XCTAssertEqual(active.matches.map(\.record.id), ["replacement"])

        let prunedCount = try await store.pruneExpired(
            now: now,
            namespace: "oval-office"
        )
        XCTAssertEqual(prunedCount, 1)

        let remaining = try await store.query(
            MemoryQuery(
                namespace: "oval-office",
                scopes: ["world:press"],
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
