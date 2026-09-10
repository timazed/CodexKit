import CodexKit
import CodexKitSQLite
import CodexKitRealm
import XCTest

final class ScopedStorageTests: XCTestCase {
    func testSQLiteAccountDirectoryUsesOwnedFilesAndIsolatesMemory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        let runtime = try SQLiteRuntimeStateStore(storageDirectory: first)
        _ = try await runtime.prepare()
        let memory = try SQLiteMemoryStore(storageDirectory: first)
        try await memory.put(.init(namespace: "shared", scope: "test", category: "preference", summary: "Private to first"))
        let other = try SQLiteMemoryStore(storageDirectory: second)
        let records = try await other.list(namespace: "shared")
        XCTAssertTrue(records.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.appendingPathComponent("CodexKit/SQLite/runtime-state.sqlite").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.appendingPathComponent("CodexKit/SQLite/memory.sqlite").path))
    }

    func testRealmAccountDirectoryUsesOwnedFilesAndIsolatesMemory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first")
        let runtime = try RealmRuntimeStateStore(storageDirectory: first)
        _ = try await runtime.prepare()
        let memory = try RealmMemoryStore(storageDirectory: first)
        try await memory.put(.init(namespace: "shared", scope: "test", category: "preference", summary: "Private to first"))
        let other = try RealmMemoryStore(storageDirectory: root.appendingPathComponent("second"))
        let records = try await other.list(namespace: "shared")
        XCTAssertTrue(records.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.appendingPathComponent("CodexKit/Realm/runtime-state.realm").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.appendingPathComponent("CodexKit/Realm/memory.realm").path))
    }

    func testAccountDirectoriesRejectExistingHostFilesAndRemoteURLs() throws {
        let hostFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        let sentinel = Data("Host-owned data must not be migrated".utf8)
        try sentinel.write(to: hostFile)
        defer { try? FileManager.default.removeItem(at: hostFile) }
        for url in [hostFile, URL(string: "https://example.invalid/database")!] {
            XCTAssertThrowsError(try SQLiteRuntimeStateStore(storageDirectory: url))
            XCTAssertThrowsError(try SQLiteMemoryStore(storageDirectory: url))
            XCTAssertThrowsError(try RealmRuntimeStateStore(storageDirectory: url))
            XCTAssertThrowsError(try RealmMemoryStore(storageDirectory: url))
        }
        XCTAssertEqual(try Data(contentsOf: hostFile), sentinel)
    }
}
