import CodexKit
@testable import CodexKitSQLite
import CodexKitUI
import SQLite3
import XCTest

extension AgentRuntimeTests {
    func testSQLiteRuntimeStoreMigratesReleasedVersionTwoWithoutLosingHistory() async throws {
        let url = temporaryRuntimeSQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let thread = AgentThread(id: "released-v2-thread", title: "Released v2")
        let message = AgentMessage(
            id: "released-v2-message",
            threadID: thread.id,
            role: .user,
            text: "Persisted before the v3 projections",
            createdAt: Date(timeIntervalSince1970: 200)
        )
        let record = AgentHistoryRecord(
            id: "released-v2-record",
            sequenceNumber: 7,
            createdAt: message.createdAt,
            item: .message(message)
        )
        let threadData = try JSONEncoder().encode(thread)
        let recordData = try JSONEncoder().encode(record)

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
        guard let database else { return XCTFail("Expected a SQLite fixture database.") }
        XCTAssertEqual(
            sqlite3_exec(
                database,
                """
                CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY);
                INSERT INTO grdb_migrations VALUES ('runtime_store_v1');
                INSERT INTO grdb_migrations VALUES ('runtime_store_v2_compaction_state');
                CREATE TABLE runtime_threads (
                    threadID TEXT PRIMARY KEY, createdAt DOUBLE NOT NULL,
                    updatedAt DOUBLE NOT NULL, status TEXT NOT NULL,
                    encodedThread BLOB NOT NULL
                );
                CREATE TABLE runtime_summaries (
                    threadID TEXT PRIMARY KEY, createdAt DOUBLE NOT NULL,
                    updatedAt DOUBLE NOT NULL, latestItemAt DOUBLE, itemCount INTEGER,
                    pendingStateKind TEXT, latestStructuredOutputFormatName TEXT,
                    encodedSummary BLOB NOT NULL
                );
                CREATE TABLE runtime_history_items (
                    storageID TEXT PRIMARY KEY, recordID TEXT NOT NULL,
                    threadID TEXT NOT NULL, sequenceNumber INTEGER NOT NULL,
                    createdAt DOUBLE NOT NULL, kind TEXT NOT NULL, turnID TEXT,
                    isCompactionMarker BOOLEAN NOT NULL DEFAULT 0,
                    isRedacted BOOLEAN NOT NULL DEFAULT 0, encodedRecord BLOB NOT NULL
                );
                CREATE TABLE runtime_structured_outputs (
                    outputID TEXT PRIMARY KEY, threadID TEXT NOT NULL,
                    formatName TEXT NOT NULL, committedAt DOUBLE NOT NULL,
                    encodedRecord BLOB NOT NULL
                );
                CREATE TABLE runtime_context_states (
                    threadID TEXT PRIMARY KEY, generation INTEGER NOT NULL,
                    encodedState BLOB NOT NULL
                );
                PRAGMA user_version = 2;
                """,
                nil,
                nil,
                nil
            ),
            SQLITE_OK
        )
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(
                database,
                "INSERT INTO runtime_threads VALUES (?, ?, ?, ?, ?)",
                -1,
                &statement,
                nil
            ),
            SQLITE_OK
        )
        sqlite3_bind_text(statement, 1, thread.id, -1, transient)
        sqlite3_bind_double(statement, 2, thread.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 3, thread.updatedAt.timeIntervalSince1970)
        sqlite3_bind_text(statement, 4, thread.status.rawValue, -1, transient)
        _ = threadData.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 5, bytes.baseAddress, Int32(bytes.count), transient)
        }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        XCTAssertEqual(sqlite3_finalize(statement), SQLITE_OK)

        statement = nil
        XCTAssertEqual(
            sqlite3_prepare_v2(
                database,
                "INSERT INTO runtime_history_items VALUES (?, ?, ?, ?, ?, ?, NULL, 0, 0, ?)",
                -1,
                &statement,
                nil
            ),
            SQLITE_OK
        )
        sqlite3_bind_text(statement, 1, "\(thread.id):7", -1, transient)
        sqlite3_bind_text(statement, 2, record.id, -1, transient)
        sqlite3_bind_text(statement, 3, thread.id, -1, transient)
        sqlite3_bind_int(statement, 4, 7)
        sqlite3_bind_double(statement, 5, record.createdAt.timeIntervalSince1970)
        sqlite3_bind_text(statement, 6, AgentHistoryItemKind.message.rawValue, -1, transient)
        _ = recordData.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 7, bytes.baseAddress, Int32(bytes.count), transient)
        }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        XCTAssertEqual(sqlite3_finalize(statement), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(database), SQLITE_OK)

        let store = try SQLiteRuntimeStateStore(url: url)
        let state = try await store.loadState()
        XCTAssertEqual(state.threads, [thread])
        XCTAssertEqual(state.historyByThread[thread.id], [record])
        XCTAssertEqual(state.nextHistorySequenceByThread[thread.id], 8)
        let metadata = try await store.readMetadata()
        XCTAssertEqual(metadata.storeSchemaVersion, 3)

        let activation = try await store.loadThreadActivationState(
            id: thread.id,
            policy: AgentThreadActivationPolicy(maximumHistoryRecordCount: 8)
        )
        XCTAssertEqual(activation.nextHistorySequence, 8)
    }

    func testSQLiteRuntimeStateStorePersistsProviderContextAcrossReload() async throws {
        let url = temporaryRuntimeSQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let thread = AgentThread(id: "thread-provider-context")
        let providerContext = AgentProviderContext(
            providerID: "openai.responses",
            payload: .object([
                "items": .array([
                    .object([
                        "id": .string("rs_1"),
                        "type": .string("reasoning"),
                        "encrypted_content": .string("encrypted-state"),
                    ]),
                ]),
                "previous_response_id": .null,
            ])
        )
        let contextState = AgentThreadContextState(
            threadID: thread.id,
            effectiveMessages: [],
            providerContext: providerContext
        )
        let store = try SQLiteRuntimeStateStore(url: url)
        try await store.saveState(
            StoredRuntimeState(
                threads: [thread],
                contextStateByThread: [thread.id: contextState]
            )
        )

        let reloaded = try SQLiteRuntimeStateStore(url: url)
        let loaded = try await reloaded.loadState()
        XCTAssertEqual(
            loaded.contextStateByThread[thread.id]?.providerContext,
            providerContext
        )
    }

    func testThreadContextStateDecodesLegacyPayloadWithoutProviderContext() throws {
        let legacy = AgentThreadContextState(
            threadID: "thread-legacy-context",
            effectiveMessages: [],
            generation: 2
        )
        let data = try JSONEncoder().encode(legacy)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["providerContext"])

        let decoded = try JSONDecoder().decode(AgentThreadContextState.self, from: data)
        XCTAssertNil(decoded.providerContext)
        XCTAssertEqual(decoded.generation, 2)
    }

    func testSQLiteRuntimeStateStorePersistsSummariesAndQueriesAcrossReload() async throws {
        let url = temporaryRuntimeSQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let backend = InMemoryAgentBackend(structuredResponseText: #"{"reply":"The replacement is shipping today.","priority":"urgent"}"#)
        let store = try SQLiteRuntimeStateStore(url: url)
        let runtime = try makeHistoryRuntime(backend: backend, approvalPresenter: AutoApprovalPresenter(), stateStore: store)

        _ = try await runtime.restore()
        _ = try await runtime.useSession(demoSession())

        let thread = try await runtime.createThread(title: "SQLite Thread")
        _ = try await runtime.send(Request(text: "Draft the shipping update."), in: thread.id, response: ShippingReplyDraft.self)

        let reloadedStore = try SQLiteRuntimeStateStore(url: url)
        let reloadedRuntime = try makeHistoryRuntime(backend: backend, approvalPresenter: AutoApprovalPresenter(), stateStore: reloadedStore)

        let metadata = try await reloadedRuntime.prepareStore()
        XCTAssertEqual(metadata.storeKind, "SQLiteRuntimeStateStore")
        XCTAssertEqual(metadata.storeSchemaVersion, 3)

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
        _ = try await runtime.useSession(demoSession())

        let thread = try await runtime.createThread(title: "SQLite Mutations")
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
        _ = try await legacyRuntime.useSession(demoSession())

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

    func testSQLiteLegacyImportRetriesAfterFailedImport() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexKitSQLiteImportRetry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacyURL = directory.appendingPathComponent("runtime.json")
        let sqliteURL = directory.appendingPathComponent("runtime.sqlite")
        try Data("invalid legacy state".utf8).write(to: legacyURL)

        let initiallyEmpty = try SQLiteRuntimeStateStore(
            url: sqliteURL,
            importingLegacyStateFrom: legacyURL
        )
        await XCTAssertThrowsErrorAsync(try await initiallyEmpty.prepare())

        let thread = AgentThread(id: "retry-import")
        try await FileRuntimeStateStore(url: legacyURL).saveState(
            StoredRuntimeState(threads: [thread])
        )
        let retried = try SQLiteRuntimeStateStore(
            url: sqliteURL,
            importingLegacyStateFrom: legacyURL
        )
        let loaded = try await retried.loadState()
        XCTAssertEqual(loaded.threads, [thread])
    }

    func testSQLiteStructuredOutputIdentityIsScopedToThread() async throws {
        let url = temporaryRuntimeSQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteRuntimeStateStore(url: url)
        let threads = [AgentThread(id: "structured-a"), AgentThread(id: "structured-b")]
        let history = Dictionary(uniqueKeysWithValues: threads.map { thread in
            let message = AgentMessage(
                id: "shared-message-id",
                threadID: thread.id,
                role: .assistant,
                text: thread.id,
                structuredOutput: AgentStructuredOutputMetadata(
                    formatName: "shared-format",
                    payload: .string(thread.id)
                )
            )
            return (thread.id, [AgentHistoryRecord(
                id: "shared-record-id",
                sequenceNumber: 1,
                createdAt: message.createdAt,
                item: .message(message)
            )])
        })
        try await store.saveState(StoredRuntimeState(
            threads: threads,
            historyByThread: history
        ))

        var outputs = try await store.execute(StructuredOutputQuery(
            formatNames: ["shared-format"]
        ))
        XCTAssertEqual(Set(outputs.map(\.threadID)), Set(threads.map(\.id)))
        try await store.apply([.redactHistoryItems(
            threadID: threads[0].id,
            itemIDs: ["shared-record-id"],
            reason: nil
        )])
        outputs = try await store.execute(StructuredOutputQuery(formatNames: ["shared-format"]))
        XCTAssertEqual(outputs.map(\.threadID), [threads[1].id])
    }

    func testSQLiteRuntimeStateStoreExternalizesImageAttachments() async throws {
        let url = temporaryRuntimeSQLiteURL()
        let attachmentsDirectory = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).codexkit-state", isDirectory: true)
            .appendingPathComponent("attachments", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: attachmentsDirectory.deletingLastPathComponent())
        }

        let imageData = Data("CODEXKIT_IMAGE_BYTES_MUST_STAY_ON_DISK_SQLITE".utf8)
        let runtime = try makeHistoryRuntime(backend: InMemoryAgentBackend(), approvalPresenter: AutoApprovalPresenter(), stateStore: try SQLiteRuntimeStateStore(url: url))
        _ = try await runtime.restore()
        _ = try await runtime.useSession(demoSession())

        let thread = try await runtime.createThread(title: "Attachment Thread")
        _ = try await runtime.send(Request(text: "here is an image", images: [.png(imageData)]), in: thread.id)

        let reloadedRuntime = try makeHistoryRuntime(backend: InMemoryAgentBackend(), approvalPresenter: AutoApprovalPresenter(), stateStore: try SQLiteRuntimeStateStore(url: url))
        let history = try await reloadedRuntime.execute(HistoryItemsQuery(threadID: thread.id, kinds: [.message]))
        guard let userRecord = history.records.first(where: { record in
            guard case let .message(message) = record.item else { return false }
            return message.role == .user
        }), case let .message(userMessage) = userRecord.item
        else { return XCTFail("Expected a persisted user message with an attachment.") }

        XCTAssertEqual(userMessage.images.count, 1)
        XCTAssertEqual(userMessage.images.first?.data, imageData)

        let attachmentFiles = try regularFiles(in: attachmentsDirectory)
        XCTAssertEqual(attachmentFiles.count, 1)
        var database: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil),
            SQLITE_OK
        )
        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(
                database,
                "SELECT encodedRecord FROM runtime_history_items WHERE recordID = ? LIMIT 1",
                -1,
                &statement,
                nil
            ),
            SQLITE_OK
        )
        let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        XCTAssertEqual(
            sqlite3_bind_text(statement, 1, userRecord.id, -1, transientDestructor),
            SQLITE_OK
        )
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        let encodedLength = Int(sqlite3_column_bytes(statement, 0))
        let encodedRecord = Data(
            bytes: sqlite3_column_blob(statement, 0),
            count: encodedLength
        )
        XCTAssertNil(encodedRecord.range(of: imageData))
        XCTAssertNil(encodedRecord.range(of: imageData.base64EncodedData()))
        XCTAssertEqual(sqlite3_finalize(statement), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(database), SQLITE_OK)
        XCTAssertNil(try Data(contentsOf: url).range(of: imageData))
        XCTAssertNil(try Data(contentsOf: url).range(of: imageData.base64EncodedData()))

        try await reloadedRuntime.redactHistoryItems([userRecord.id], in: thread.id)
        XCTAssertTrue(try regularFiles(in: attachmentsDirectory).isEmpty)
    }

    func testSQLiteFailedHistoryWriteRemovesStagedAttachment() async throws {
        let url = temporaryRuntimeSQLiteURL()
        let attachmentRoot = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).codexkit-state", isDirectory: true)
            .appendingPathComponent("attachments", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: attachmentRoot.deletingLastPathComponent())
        }
        let store = try SQLiteRuntimeStateStore(url: url)
        let thread = AgentThread(id: "sqlite-staged-rollback")
        try await store.apply([.upsertThread(thread)])
        let message = AgentMessage(
            id: "invalid-message",
            threadID: thread.id,
            role: .user,
            text: "Out of sequence",
            images: [.png(Data("UNCOMMITTED_SQLITE_IMAGE".utf8))]
        )
        let record = AgentHistoryRecord(
            sequenceNumber: 2,
            createdAt: message.createdAt,
            item: .message(message)
        )

        await XCTAssertThrowsErrorAsync(
            try await store.apply([.appendHistoryItems(threadID: thread.id, items: [record])])
        )
        XCTAssertTrue(try regularFiles(in: attachmentRoot).isEmpty)
    }

    func testSQLiteContextCleanupPreservesAttachmentsStillOwnedByHistory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexKitSQLiteAttachmentOwnership-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteRuntimeStateStore(url: directory.appendingPathComponent("runtime.sqlite"))
        let thread = AgentThread(id: "attachment-ownership")
        let messages = [1, 2].map { byte in
            AgentMessage(
                id: "message-\(byte)",
                threadID: thread.id,
                role: byte == 1 ? .user : .assistant,
                text: "message \(byte)",
                images: [.png(Data([UInt8(byte)]), id: "image-\(byte)")]
            )
        }
        let records = messages.enumerated().map { offset, message in
            AgentHistoryRecord(
                id: "record-\(offset + 1)",
                sequenceNumber: offset + 1,
                createdAt: message.createdAt,
                item: .message(message)
            )
        }
        try await store.saveState(StoredRuntimeState(
            threads: [thread],
            historyByThread: [thread.id: records],
            contextStateByThread: [thread.id: AgentThreadContextState(
                threadID: thread.id,
                effectiveMessages: messages
            )]
        ))
        try await store.apply([.redactHistoryItems(
            threadID: thread.id,
            itemIDs: [records[0].id],
            reason: nil
        )])

        let loaded = try await store.loadState()
        guard case let .message(retained) = loaded.historyByThread[thread.id]?.last?.item else {
            return XCTFail("Expected the unredacted attachment to remain readable.")
        }
        XCTAssertEqual(retained.images.first?.data, Data([2]))
    }

    func testSQLiteGenericHistoryPagingDecodesOnlyTheRequestedWindow() async throws {
        let url = temporaryRuntimeSQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteRuntimeStateStore(url: url)
        let thread = AgentThread(id: "sqlite-large-history")
        let records = (1 ... 1_000).map { sequence in
            let message = AgentMessage(
                id: "message-\(sequence)",
                threadID: thread.id,
                role: sequence.isMultiple(of: 2) ? .assistant : .user,
                text: "message \(sequence)",
                createdAt: Date(timeIntervalSince1970: Double(sequence))
            )
            return AgentHistoryRecord(
                sequenceNumber: sequence,
                createdAt: message.createdAt,
                item: .message(message)
            )
        }
        try await store.saveState(StoredRuntimeState(
            threads: [thread],
            historyByThread: [thread.id: records]
        ))

        await store.resetActivationDiagnostics()
        let result = try await store.execute(HistoryItemsQuery(
            threadID: thread.id,
            page: AgentQueryPage(limit: 9)
        ))
        let diagnostics = await store.activationDiagnostics()

        XCTAssertEqual(result.records.count, 9)
        XCTAssertEqual(diagnostics.decodedHistoryBodyCount, 9)
        XCTAssertTrue(result.hasMoreBefore)
    }

    func testSQLiteRedactionSummaryRebuildDoesNotDecodeUnrelatedHistory() async throws {
        let url = temporaryRuntimeSQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteRuntimeStateStore(url: url)
        let thread = AgentThread(id: "sqlite-redaction-large-history")
        let records = (1 ... 1_000).map { sequence in
            let message = AgentMessage(
                id: "message-\(sequence)",
                threadID: thread.id,
                role: sequence.isMultiple(of: 2) ? .assistant : .user,
                text: "message \(sequence)",
                createdAt: Date(timeIntervalSince1970: Double(sequence))
            )
            return AgentHistoryRecord(
                sequenceNumber: sequence,
                createdAt: message.createdAt,
                item: .message(message)
            )
        }
        try await store.saveState(StoredRuntimeState(
            threads: [thread],
            historyByThread: [thread.id: records]
        ))

        // If summary rebuilding decodes the whole thread, this unrelated user
        // row makes the redaction fail. It is intentionally outside every
        // indexed latest-row category used by the bounded rebuild.
        var database: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil),
            SQLITE_OK
        )
        XCTAssertEqual(
            sqlite3_exec(
                database,
                """
                UPDATE runtime_history_items
                SET encodedRecord = X'00'
                WHERE threadID = 'sqlite-redaction-large-history'
                  AND sequenceNumber = 501;
                """,
                nil,
                nil,
                nil
            ),
            SQLITE_OK
        )
        XCTAssertEqual(sqlite3_close(database), SQLITE_OK)

        try await store.apply([.redactHistoryItems(
            threadID: thread.id,
            itemIDs: [records[0].id],
            reason: AgentRedactionReason(code: "performance-test")
        )])
        let summary = try await store.fetchThreadSummary(id: thread.id)
        XCTAssertEqual(summary.itemCount, 1_000)
        XCTAssertEqual(summary.latestAssistantMessagePreview, "message 1000")
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
        _ = try await runtime.useSession(demoSession())

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
