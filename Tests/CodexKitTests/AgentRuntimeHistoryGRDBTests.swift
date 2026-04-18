import CodexKit
import CodexKitUI
import XCTest

extension AgentRuntimeTests {
    func testSQLiteRuntimeStateStorePersistsSummariesAndQueriesAcrossReload() async throws {
        let url = temporaryRuntimeSQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let backend = InMemoryAgentBackend(structuredResponseText: #"{"reply":"The replacement is shipping today.","priority":"urgent"}"#)
        let store = try SQLiteRuntimeStateStore(url: url)
        let runtime = try makeHistoryRuntime(backend: backend, approvalPresenter: AutoApprovalPresenter(), stateStore: store)

        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread(title: "GRDB Thread")
        _ = try await runtime.send(Request(text: "Draft the shipping update."), in: thread.id, response: ShippingReplyDraft.self)

        let reloadedStore = try SQLiteRuntimeStateStore(url: url)
        let reloadedRuntime = try makeHistoryRuntime(backend: backend, approvalPresenter: AutoApprovalPresenter(), stateStore: reloadedStore)

        let metadata = try await reloadedRuntime.prepareStore()
        XCTAssertEqual(metadata.storeKind, "SQLiteRuntimeStateStore")
        XCTAssertEqual(metadata.storeSchemaVersion, 2)

        let summary = try await reloadedRuntime.fetchThreadSummary(id: thread.id)
        XCTAssertEqual(summary.latestTurnStatus, .completed)
        XCTAssertEqual(summary.latestStructuredOutputMetadata?.formatName, "shipping_reply_draft")

        let snapshots = try await reloadedRuntime.execute(ThreadSnapshotQuery(threadIDs: [thread.id]))
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.threadID, thread.id)

        let history = try await reloadedRuntime.execute(HistoryItemsQuery(threadID: thread.id, kinds: [.message, .structuredOutput]))
        XCTAssertFalse(history.records.isEmpty)

        let typed = try await reloadedRuntime.fetchLatestStructuredOutput(id: thread.id, as: ShippingReplyDraft.self)
        XCTAssertEqual(typed, ShippingReplyDraft(reply: "The replacement is shipping today.", priority: "urgent"))
    }

    func testSQLiteRuntimeStateStorePersistsRedactionAndDeletion() async throws {
        let url = temporaryRuntimeSQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let runtime = try makeHistoryRuntime(backend: InMemoryAgentBackend(), approvalPresenter: AutoApprovalPresenter(), stateStore: try SQLiteRuntimeStateStore(url: url))
        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread(title: "GRDB Mutations")
        _ = try await runtime.send(Request(text: "please redact me"), in: thread.id)

        let messageHistory = try await runtime.execute(HistoryItemsQuery(threadID: thread.id, kinds: [.message]))
        guard let firstMessage = messageHistory.records.first else { return XCTFail("Expected a persisted message record.") }

        try await runtime.redactHistoryItems([firstMessage.id], in: thread.id)

        let reloadedAfterRedaction = try makeHistoryRuntime(backend: InMemoryAgentBackend(), approvalPresenter: AutoApprovalPresenter(), stateStore: try SQLiteRuntimeStateStore(url: url))
        let redactedHistory = try await reloadedAfterRedaction.execute(HistoryItemsQuery(threadID: thread.id, kinds: [.message]))

        guard let redactedRecord = redactedHistory.records.first(where: { $0.id == firstMessage.id }) else {
            return XCTFail("Expected the redacted record to still be queryable.")
        }
        XCTAssertNotNil(redactedRecord.redaction)

        try await reloadedAfterRedaction.deleteThread(id: thread.id)
        let deletedRuntime = try makeHistoryRuntime(backend: InMemoryAgentBackend(), approvalPresenter: AutoApprovalPresenter(), stateStore: try SQLiteRuntimeStateStore(url: url))
        let deletedThreads = try await deletedRuntime.execute(ThreadMetadataQuery(threadIDs: [thread.id]))
        XCTAssertTrue(deletedThreads.isEmpty)
    }

    func testSQLiteRuntimeStateStoreImportsLegacyFileStateOnFirstPrepare() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let legacyURL = directory.appendingPathComponent("runtime-state").appendingPathExtension("json")
        let sqliteURL = directory.appendingPathComponent("runtime-state").appendingPathExtension("sqlite")

        let backend = InMemoryAgentBackend(structuredResponseText: #"{"reply":"Legacy import payload.","priority":"normal"}"#)
        let legacyRuntime = try makeHistoryRuntime(backend: backend, approvalPresenter: AutoApprovalPresenter(), stateStore: FileRuntimeStateStore(url: legacyURL))
        _ = try await legacyRuntime.restore()
        _ = try await legacyRuntime.signIn()

        let thread = try await legacyRuntime.createThread(title: "Legacy File Thread")
        _ = try await legacyRuntime.send(Request(text: "Create a legacy payload."), in: thread.id, response: ShippingReplyDraft.self)

        let importedStore = try SQLiteRuntimeStateStore(url: sqliteURL)
        let importedRuntime = try makeHistoryRuntime(backend: backend, approvalPresenter: AutoApprovalPresenter(), stateStore: importedStore)
        _ = try await importedRuntime.prepareStore()

        let summary = try await importedRuntime.fetchThreadSummary(id: thread.id)
        let importedHistory = try await importedRuntime.execute(
            HistoryItemsQuery(threadID: thread.id, kinds: [.message, .structuredOutput])
        )
        XCTAssertEqual(summary.latestStructuredOutputMetadata?.formatName, "shipping_reply_draft")
        XCTAssertFalse(importedHistory.records.isEmpty)
    }

    func testSQLiteRuntimeStateStoreExternalizesImageAttachments() async throws {
        let url = temporaryRuntimeSQLiteURL()
        let attachmentsDirectory = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.deletingPathExtension().lastPathComponent).codexkit-state", isDirectory: true)
            .appendingPathComponent("attachments", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: attachmentsDirectory.deletingLastPathComponent())
        }

        let imageData = Data([0x89, 0x50, 0x4E, 0x47, 0xDE, 0xAD, 0xBE, 0xEF])
        let runtime = try makeHistoryRuntime(backend: InMemoryAgentBackend(), approvalPresenter: AutoApprovalPresenter(), stateStore: try SQLiteRuntimeStateStore(url: url))
        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread(title: "Attachment Thread")
        _ = try await runtime.send(Request(text: "here is an image", images: [.png(imageData)]), in: thread.id)

        let reloadedRuntime = try makeHistoryRuntime(backend: InMemoryAgentBackend(), approvalPresenter: AutoApprovalPresenter(), stateStore: try SQLiteRuntimeStateStore(url: url))
        let history = try await reloadedRuntime.execute(HistoryItemsQuery(threadID: thread.id, kinds: [.message]))
        guard let userMessage = history.records.compactMap({ record -> AgentMessage? in
            guard case let .message(message) = record.item, message.role == .user else { return nil }
            return message
        }).first else { return XCTFail("Expected a persisted user message with an attachment.") }

        XCTAssertEqual(userMessage.images.count, 1)
        XCTAssertEqual(userMessage.images.first?.data, imageData)

        let attachmentFiles = try FileManager.default.contentsOfDirectory(
            at: attachmentsDirectory.appendingPathComponent(thread.id, isDirectory: true)
                .appendingPathComponent(userMessage.id, isDirectory: true),
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(attachmentFiles.count, 1)
        XCTAssertNil(try Data(contentsOf: url).range(of: imageData.base64EncodedData()))
    }

    func testSQLiteRuntimeStateStoreTreatsExplicitEmptyFiltersAsMatchNothing() async throws {
        let url = temporaryRuntimeSQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let backend = InMemoryAgentBackend(structuredResponseText: #"{"reply":"The replacement is shipping today.","priority":"urgent"}"#)
        let runtime = try makeHistoryRuntime(
            backend: backend,
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: try SQLiteRuntimeStateStore(url: url)
        )

        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread(title: "Explicit Empty Filters")
        _ = try await runtime.send(
            Request(text: "Draft the shipping update."),
            in: thread.id,
            response: ShippingReplyDraft.self
        )

        let threads = try await runtime.execute(ThreadMetadataQuery(threadIDs: []))
        XCTAssertTrue(threads.isEmpty)

        let snapshots = try await runtime.execute(ThreadSnapshotQuery(threadIDs: []))
        XCTAssertTrue(snapshots.isEmpty)

        let history = try await runtime.execute(HistoryItemsQuery(threadID: thread.id, kinds: []))
        XCTAssertTrue(history.records.isEmpty)

        let structured = try await runtime.execute(StructuredOutputQuery(threadIDs: [], formatNames: []))
        XCTAssertTrue(structured.isEmpty)
    }
}
