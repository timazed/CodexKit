import CodexKit
import CodexKitRealm
import CodexKitSQLite
import XCTest

final class MemoryCompactionSafetyTests: XCTestCase {
    func testInMemoryStoreRejectsReplacementAmongSources() async throws {
        try await assertRejectsReplacementAmongSources(InMemoryMemoryStore())
    }

    func testSQLiteStoreRejectsReplacementAmongSources() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        try await assertRejectsReplacementAmongSources(SQLiteMemoryStore(url: url))
    }

    func testRealmStoreRejectsReplacementAmongSources() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexKitCompactionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await assertRejectsReplacementAmongSources(RealmMemoryStore(
            url: directory.appendingPathComponent("memory.realm")
        ))
    }

    private func assertRejectsReplacementAmongSources(
        _ store: any MemoryStoring
    ) async throws {
        let replacement = MemoryRecord(
            id: "replacement",
            namespace: "assistant",
            scope: "project",
            category: "summary",
            summary: "replacement"
        )
        do {
            try await store.compact(MemoryCompactionRequest(
                replacement: replacement,
                sourceIDs: ["source", replacement.id]
            ))
            XCTFail("Expected invalid self-referencing compaction to fail.")
        } catch {
            XCTAssertEqual(
                error as? MemoryStoreError,
                .invalidCompaction("replacement id must not also appear in sourceIDs.")
            )
        }
        let records = try await store.list(
            namespace: replacement.namespace,
            includeArchived: true
        )
        XCTAssertTrue(records.isEmpty)
    }
}
