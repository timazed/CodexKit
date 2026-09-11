import CodexKit
import CodexKitRealm
import CodexKitSQLite
import XCTest

final class RuntimeHistoryValidationTests: XCTestCase {
    func testEveryRuntimeStoreAppliesTheSameHistorySequenceContract() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexKitHistoryValidation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let stores: [(TestStorageBackend, any RuntimeStateStoring)] = [
            (.inMemory, InMemoryRuntimeStateStore()),
            (.file, FileRuntimeStateStore(url: directory.appendingPathComponent("runtime.json"))),
            (.sqlite, try SQLiteRuntimeStateStore(
                url: directory.appendingPathComponent("runtime.sqlite"),
                importingLegacyStateFrom: directory.appendingPathComponent("missing-legacy.json")
            )),
            (.realm, try RealmRuntimeStateStore(
                url: directory.appendingPathComponent("runtime.realm"),
                importingLegacyStateFrom: directory.appendingPathComponent("missing-legacy.json")
            )),
        ]

        for (name, store) in stores {
            do {
                try await assertHistorySequenceContract(store)
            } catch {
                XCTFail("\(name) validation failed: \(error)")
                throw error
            }
        }
    }

    func testEveryRuntimeStoreRejectsInvalidSnapshotHistory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexKitSnapshotValidation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let stores: [any RuntimeStateStoring] = [
            InMemoryRuntimeStateStore(),
            FileRuntimeStateStore(url: directory.appendingPathComponent("runtime.json")),
            try SQLiteRuntimeStateStore(
                url: directory.appendingPathComponent("runtime.sqlite"),
                importingLegacyStateFrom: directory.appendingPathComponent("missing-legacy.json")
            ),
            try RealmRuntimeStateStore(
                url: directory.appendingPathComponent("runtime.realm"),
                importingLegacyStateFrom: directory.appendingPathComponent("missing-legacy.json")
            ),
        ]
        let thread = AgentThread(id: "snapshot-thread")
        let invalid = StoredRuntimeState(
            threads: [thread],
            historyByThread: [thread.id: [
                historyRecord(sequence: 5, threadID: thread.id),
                historyRecord(sequence: 7, threadID: thread.id),
            ]]
        )

        for store in stores {
            await XCTAssertThrowsErrorAsync(try await store.saveState(invalid))
            let preservedState = try await store.loadState()
            XCTAssertTrue(preservedState.historyByThread.isEmpty)
        }
    }

    private func assertHistorySequenceContract(
        _ store: any RuntimeStateStoring
    ) async throws {
        let thread = AgentThread(id: "history-thread")
        try await store.apply([
            .upsertThread(thread),
            .restoreHistoryItems(
                threadID: thread.id,
                items: [historyRecord(sequence: 7, threadID: thread.id)]
            ),
            .appendHistoryItems(
                threadID: thread.id,
                items: [historyRecord(sequence: 8, threadID: thread.id)]
            ),
        ])

        await XCTAssertThrowsErrorAsync(try await store.apply([
            .restoreHistoryItems(
                threadID: thread.id,
                items: [self.historyRecord(sequence: 10, threadID: thread.id)]
            ),
        ]))
        await XCTAssertThrowsErrorAsync(try await store.apply([
            .appendHistoryItems(
                threadID: thread.id,
                items: [self.historyRecord(sequence: 9, threadID: "different-thread")]
            ),
        ]))

        let state = try await store.loadState()
        XCTAssertEqual(state.historyByThread[thread.id]?.map(\.sequenceNumber), [7, 8])
    }

    private func historyRecord(sequence: Int, threadID: String) -> AgentHistoryRecord {
        let message = AgentMessage(
            id: "message-\(sequence)-\(threadID)",
            threadID: threadID,
            role: .user,
            text: "message \(sequence)"
        )
        return AgentHistoryRecord(
            sequenceNumber: sequence,
            createdAt: message.createdAt,
            item: .message(message)
        )
    }
}
