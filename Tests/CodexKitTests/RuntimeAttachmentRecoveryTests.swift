@testable import CodexKit
@testable import CodexKitRealm
@testable import CodexKitSQLite
import XCTest

final class RuntimeAttachmentRecoveryTests: XCTestCase {
    func testSQLitePreparationRemovesPromotionThatNeverReachedTheDatabase() async throws {
        let fixture = try makeFixture(storeName: "runtime.sqlite")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let databaseStore = try SQLiteRuntimeStateStore(url: fixture.storeURL)
        _ = try await databaseStore.prepare()
        let attachmentStore = RuntimeAttachmentStore(rootURL: fixture.attachmentRootURL)
        var batch = try attachmentStore.stageAttachments(in: attachmentState())
        try attachmentStore.promote(&batch)

        XCTAssertEqual(try storageKeyCount(in: attachmentStore), 1)
        XCTAssertEqual(try pendingPromotionKeyCount(in: attachmentStore), 1)

        _ = try await SQLiteRuntimeStateStore(url: fixture.storeURL).prepare()

        XCTAssertEqual(try storageKeyCount(in: attachmentStore), 0)
        XCTAssertEqual(try pendingPromotionKeyCount(in: attachmentStore), 0)
    }

    func testSQLitePreparationKeepsPromotionCommittedBeforeJournalCleanup() async throws {
        let fixture = try makeFixture(storeName: "runtime.sqlite")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let databaseStore = try SQLiteRuntimeStateStore(url: fixture.storeURL)
        _ = try await databaseStore.prepare()
        let state = attachmentState()
        let attachmentStore = RuntimeAttachmentStore(rootURL: fixture.attachmentRootURL)
        var interruptedBatch = try attachmentStore.stageAttachments(in: state)
        try attachmentStore.promote(&interruptedBatch)

        let thread = try XCTUnwrap(state.threads.first)
        let history = try XCTUnwrap(state.historyByThread[thread.id])
        try await databaseStore.apply([
            .upsertThread(thread),
            .appendHistoryItems(threadID: thread.id, items: history),
        ])
        XCTAssertGreaterThan(try pendingPromotionKeyCount(in: attachmentStore), 0)

        let reopened = try SQLiteRuntimeStateStore(url: fixture.storeURL)
        _ = try await reopened.prepare()
        let loaded = try await reopened.loadState()

        XCTAssertEqual(loaded.historyByThread[thread.id], history)
        XCTAssertEqual(try storageKeyCount(in: attachmentStore), 1)
        XCTAssertEqual(try pendingPromotionKeyCount(in: attachmentStore), 0)
    }

    func testRealmPreparationRemovesPromotionThatNeverReachedTheDatabase() async throws {
        let fixture = try makeFixture(storeName: "runtime.realm")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let databaseStore = try RealmRuntimeStateStore(url: fixture.storeURL)
        _ = try await databaseStore.prepare()
        let attachmentStore = RuntimeAttachmentStore(rootURL: fixture.attachmentRootURL)
        var batch = try attachmentStore.stageAttachments(in: attachmentState())
        try attachmentStore.promote(&batch)

        XCTAssertEqual(try storageKeyCount(in: attachmentStore), 1)
        XCTAssertEqual(try pendingPromotionKeyCount(in: attachmentStore), 1)

        _ = try await RealmRuntimeStateStore(url: fixture.storeURL).prepare()

        XCTAssertEqual(try storageKeyCount(in: attachmentStore), 0)
        XCTAssertEqual(try pendingPromotionKeyCount(in: attachmentStore), 0)
    }

    func testCorruptedAttachmentFailsIntegrityCheckAndCanBeRepaired() throws {
        let fixture = try makeFixture(storeName: "runtime.sqlite")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = RuntimeAttachmentStore(rootURL: fixture.attachmentRootURL)
        let original = AgentImageAttachment.png(
            Data("ORIGINAL_IMAGE_DATA".utf8),
            id: "repair-image"
        )
        let reference = try store.persist(
            original,
            threadID: "repair-thread",
            recordID: "repair-message",
            index: 0
        )
        let fileURL = fixture.attachmentRootURL.appendingPathComponent(reference.storageKey)
        try Data("CORRUPTED_IMAGE_DATA".utf8).write(to: fileURL, options: .atomic)

        XCTAssertThrowsError(try store.load(reference)) { error in
            XCTAssertEqual(
                error as? RuntimeAttachmentStoreError,
                .integrityCheckFailed(reference.storageKey)
            )
        }

        _ = try store.persist(
            original,
            threadID: "repair-thread",
            recordID: "repair-message",
            index: 0
        )
        XCTAssertEqual(try store.load(reference), original)
    }

    private func makeFixture(
        storeName: String
    ) throws -> (directory: URL, storeURL: URL, attachmentRootURL: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexKitAttachmentRecovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let storeURL = directory.appendingPathComponent(storeName)
        let attachmentRootURL = directory
            .appendingPathComponent("\(storeName).codexkit-state", isDirectory: true)
            .appendingPathComponent("attachments", isDirectory: true)
        return (directory, storeURL, attachmentRootURL)
    }

    private func attachmentState() -> StoredRuntimeState {
        let thread = AgentThread(id: "recovery-thread")
        let message = AgentMessage(
            id: "recovery-message",
            threadID: thread.id,
            role: .user,
            text: "attachment",
            images: [.png(Data("RECOVERY_IMAGE".utf8), id: "recovery-image")]
        )
        return StoredRuntimeState(
            threads: [thread],
            historyByThread: [thread.id: [AgentHistoryRecord(
                sequenceNumber: 1,
                createdAt: message.createdAt,
                item: .message(message)
            )]]
        )
    }

    private func storageKeyCount(in store: RuntimeAttachmentStore) throws -> Int {
        try countKeys(using: store.makeStorageKeyIterator())
    }

    private func pendingPromotionKeyCount(in store: RuntimeAttachmentStore) throws -> Int {
        try countKeys(using: store.makePendingPromotionStorageKeyIterator())
    }

    private func countKeys(
        using iterator: RuntimeAttachmentStorageKeyIterator
    ) throws -> Int {
        var count = 0
        while true {
            let batch = try iterator.nextBatch()
            guard !batch.isEmpty else { return count }
            count += batch.count
        }
    }

    private func countKeys(
        using iterator: RuntimeAttachmentPromotionKeyIterator
    ) throws -> Int {
        var count = 0
        while true {
            let batch = try iterator.nextBatch()
            guard !batch.isEmpty else { return count }
            count += batch.count
        }
    }
}
