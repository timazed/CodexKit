import CodexKit
import XCTest

final class FileRuntimeStateStoreSafetyTests: XCTestCase {
    func testRejectsFutureManifestWithoutRewritingIt() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let data = Data(#"{"storageVersion":4,"generation":"00000000-0000-0000-0000-000000000001","threads":[],"summariesByThread":{},"contextStateByThread":{},"nextHistorySequenceByThread":{}}"#.utf8)
        try data.write(to: fixture.url, options: .atomic)

        do {
            _ = try await FileRuntimeStateStore(url: fixture.url).loadState()
            XCTFail("Expected an unsupported manifest version to fail.")
        } catch {}

        XCTAssertEqual(try Data(contentsOf: fixture.url), data)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.sidecarURL.appendingPathComponent("generations").path
        ))
    }

    func testRejectsMalformedRecognizedManifestInsteadOfTreatingItAsLegacyState() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let data = Data(#"{"storageVersion":3,"generation":"00000000-0000-0000-0000-000000000001","summariesByThread":{},"contextStateByThread":{},"nextHistorySequenceByThread":{}}"#.utf8)
        try data.write(to: fixture.url, options: .atomic)

        do {
            _ = try await FileRuntimeStateStore(url: fixture.url).loadState()
            XCTFail("Expected a malformed manifest to fail.")
        } catch {}

        XCTAssertEqual(try Data(contentsOf: fixture.url), data)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.sidecarURL.appendingPathComponent("generations").path
        ))
    }

    func testRejectsManifestGenerationThatIsNotAUUID() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let data = Data(#"{"storageVersion":3,"generation":"../outside","threads":[],"summariesByThread":{},"contextStateByThread":{},"nextHistorySequenceByThread":{}}"#.utf8)
        try data.write(to: fixture.url, options: .atomic)

        do {
            _ = try await FileRuntimeStateStore(url: fixture.url).loadState()
            XCTFail("Expected an unsafe generation to fail.")
        } catch {}

        XCTAssertEqual(try Data(contentsOf: fixture.url), data)
    }

    func testMigratesVersionOneInlineContextImagesToVersionThreeAttachments() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let imageData = Data("VERSION_ONE_INLINE_IMAGE".utf8)
        let thread = AgentThread(id: "legacy-context")
        let context = AgentThreadContextState(
            threadID: thread.id,
            effectiveMessages: [AgentMessage(
                threadID: thread.id,
                role: .user,
                text: "legacy",
                images: [.png(imageData)]
            )]
        )
        let manifest = LegacyFileRuntimeStateManifest(
            threads: [thread],
            contextStateByThread: [thread.id: context]
        )
        try JSONEncoder().encode(manifest).write(to: fixture.url, options: .atomic)

        let loaded = try await FileRuntimeStateStore(url: fixture.url).loadState()

        XCTAssertEqual(loaded.contextStateByThread[thread.id], context)
        let migratedData = try Data(contentsOf: fixture.url)
        let migratedJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: migratedData) as? [String: Any]
        )
        XCTAssertEqual(migratedJSON["storageVersion"] as? Int, 3)
        XCTAssertNil(migratedData.range(of: imageData))
        XCTAssertNil(migratedData.range(of: imageData.base64EncodedData()))
    }

    func testExistingAttachmentIsReferencedWithoutBeingRestaged() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let attachmentRoot = fixture.sidecarURL.appendingPathComponent("attachments", isDirectory: true)
        let store = RuntimeAttachmentStore(rootURL: attachmentRoot)
        let thread = AgentThread(id: "existing-attachment")
        let message = AgentMessage(
            id: "existing-message",
            threadID: thread.id,
            role: .user,
            text: "image",
            images: [.png(Data("DO_NOT_RESTAGE".utf8))]
        )
        let state = StoredRuntimeState(
            threads: [thread],
            historyByThread: [thread.id: [AgentHistoryRecord(
                sequenceNumber: 1,
                createdAt: message.createdAt,
                item: .message(message)
            )]]
        )

        var initialBatch = try store.stageAttachments(in: state)
        try store.promote(&initialBatch)
        let stagingURL = attachmentRoot.appendingPathComponent(".codexkit-staging", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingURL.path))

        var repeatedBatch = try store.stageAttachments(in: state)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingURL.path))
        try store.promote(&repeatedBatch)
        let iterator = store.makeStorageKeyIterator()
        XCTAssertEqual(try iterator.nextBatch().count, 1)
        XCTAssertTrue(try iterator.nextBatch().isEmpty)
    }

    func testCurrentManifestFailsClosedWhenHistoryFileIsMissing() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let thread = AgentThread(id: "missing-history")
        let store = FileRuntimeStateStore(url: fixture.url)
        try await store.saveState(StoredRuntimeState(threads: [thread]))

        try FileManager.default.removeItem(at: try historyURL(for: thread.id, fixture: fixture))

        await XCTAssertThrowsErrorAsync(try await store.fetchThreadHistory(
            id: thread.id,
            query: AgentHistoryQuery()
        ))
    }

    func testCurrentManifestRejectsLegacyInlineHistoryPayload() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let thread = AgentThread(id: "inline-history")
        let message = AgentMessage(
            id: "inline-message",
            threadID: thread.id,
            role: .user,
            text: "must not be accepted by the current schema",
            images: [.png(Data("INLINE_IMAGE".utf8))]
        )
        let history = [AgentHistoryRecord(
            sequenceNumber: 1,
            createdAt: message.createdAt,
            item: .message(message)
        )]
        let store = FileRuntimeStateStore(url: fixture.url)
        try await store.saveState(StoredRuntimeState(
            threads: [thread],
            historyByThread: [thread.id: history]
        ))
        try JSONEncoder().encode(history).write(
            to: try historyURL(for: thread.id, fixture: fixture),
            options: .atomic
        )

        await XCTAssertThrowsErrorAsync(try await store.fetchThreadHistory(
            id: thread.id,
            query: AgentHistoryQuery()
        ))
    }

    func testFetchingOneHistoryDoesNotDecodeUnrelatedContextAttachments() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let target = AgentThread(id: "target-history")
        let unrelated = AgentThread(id: "unrelated-context")
        let unrelatedMessage = AgentMessage(
            id: "unrelated-image",
            threadID: unrelated.id,
            role: .user,
            text: "image",
            images: [.png(Data("UNRELATED_ATTACHMENT".utf8))]
        )
        let store = FileRuntimeStateStore(url: fixture.url)
        try await store.saveState(StoredRuntimeState(
            threads: [target, unrelated],
            contextStateByThread: [unrelated.id: AgentThreadContextState(
                threadID: unrelated.id,
                effectiveMessages: [unrelatedMessage]
            )]
        ))
        let generationURL = try currentGenerationURL(fixture: fixture)
        try FileManager.default.removeItem(
            at: generationURL.appendingPathComponent("attachments", isDirectory: true)
        )

        let page = try await store.fetchThreadHistory(
            id: target.id,
            query: AgentHistoryQuery()
        )
        XCTAssertTrue(page.items.isEmpty)
    }

    private func makeFixture() throws -> (directory: URL, url: URL, sidecarURL: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexKitFileManifestTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("runtime.json")
        return (
            directory,
            url,
            directory.appendingPathComponent("runtime.json.codexkit-state", isDirectory: true)
        )
    }

    private func currentGenerationURL(
        fixture: (directory: URL, url: URL, sidecarURL: URL)
    ) throws -> URL {
        let manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixture.url)) as? [String: Any]
        )
        let generation = try XCTUnwrap(manifest["generation"] as? String)
        return fixture.sidecarURL
            .appendingPathComponent("generations", isDirectory: true)
            .appendingPathComponent(generation, isDirectory: true)
    }

    private func historyURL(
        for threadID: String,
        fixture: (directory: URL, url: URL, sidecarURL: URL)
    ) throws -> URL {
        try currentGenerationURL(fixture: fixture)
            .appendingPathComponent("threads", isDirectory: true)
            .appendingPathComponent(RuntimeAttachmentStore.safePathComponent(threadID))
            .appendingPathExtension("json")
    }
}

private struct LegacyFileRuntimeStateManifest: Encodable {
    let storageVersion = 1
    let threads: [AgentThread]
    let summariesByThread: [String: AgentThreadSummary] = [:]
    let contextStateByThread: [String: AgentThreadContextState]
    let nextHistorySequenceByThread: [String: Int] = [:]
}
