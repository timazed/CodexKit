@testable import CodexKit
@testable import CodexKitRealm
@testable import CodexKitSQLite
import RealmSwift
import SQLite3
import XCTest

final class PersistenceHardeningTests: XCTestCase {
    func testPersistentRuntimeStoresExternalizeNestedImagePayloads() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let storeConfigurations: [(any RuntimeStateStoring, URL)] = [
            (
                FileRuntimeStateStore(url: fixture.appendingPathComponent("nested-images.json")),
                fixture.appendingPathComponent("nested-images.json")
            ),
            (
                try SQLiteRuntimeStateStore(
                    url: fixture.appendingPathComponent("nested-images.sqlite"),
                    importingLegacyStateFrom: fixture.appendingPathComponent("missing-sqlite.json")
                ),
                fixture.appendingPathComponent("nested-images.sqlite")
            ),
            (
                try RealmRuntimeStateStore(
                    url: fixture.appendingPathComponent("nested-images.realm"),
                    importingLegacyStateFrom: fixture.appendingPathComponent("missing-realm.json")
                ),
                fixture.appendingPathComponent("nested-images.realm")
            ),
        ]

        for (index, configuration) in storeConfigurations.enumerated() {
            let threadID = "nested-images-\(index)"
            let turnID = "nested-turn-\(index)"
            let invocation = ToolInvocation(
                id: "nested-invocation-\(index)",
                threadID: threadID,
                turnID: turnID,
                toolName: "render_image",
                arguments: .object([:])
            )
            let interactionImage = AgentImageAttachment.png(
                Data("INTERACTION_IMAGE_BYTES_\(index)".utf8),
                id: "interaction-image"
            )
            let resultImage = AgentImageAttachment.png(
                Data("RESULT_IMAGE_BYTES_\(index)".utf8),
                id: "result-image"
            )
            let interactionResult = ToolResultEnvelope(
                invocationID: invocation.id,
                toolName: invocation.toolName,
                success: true,
                content: [.image(try XCTUnwrap(URL(string: interactionImage.dataURLString)))]
            )
            let standaloneResult = ToolResultEnvelope(
                invocationID: invocation.id,
                toolName: invocation.toolName,
                success: true,
                content: [.image(try XCTUnwrap(URL(string: resultImage.dataURLString)))]
            )
            let message = AgentMessage(
                id: "nested-message",
                threadID: threadID,
                role: .tool,
                text: "Rendered an image",
                toolInteraction: AgentToolInteraction(
                    invocation: invocation,
                    result: interactionResult
                )
            )
            let records = [
                AgentHistoryRecord(
                    sequenceNumber: 1,
                    createdAt: message.createdAt,
                    item: .message(message)
                ),
                AgentHistoryRecord(
                    sequenceNumber: 2,
                    createdAt: Date(),
                    item: .toolCall(AgentToolCallRecord(invocation: invocation))
                ),
                AgentHistoryRecord(
                    sequenceNumber: 3,
                    createdAt: Date(),
                    item: .toolResult(AgentToolResultRecord(
                        threadID: threadID,
                        turnID: turnID,
                        result: standaloneResult
                    ))
                ),
            ]

            try await configuration.0.apply([
                .upsertThread(AgentThread(id: threadID)),
                .appendHistoryItems(threadID: threadID, items: records),
            ])

            let loaded = try await configuration.0.loadState()
            let loadedRecords = try XCTUnwrap(loaded.historyByThread[threadID])
            guard case let .message(loadedMessage) = loadedRecords[0].item,
                  case let .image(loadedInteractionURL) = try XCTUnwrap(
                      loadedMessage.toolInteraction?.result.content.first
                  ),
                  case let .toolResult(loadedResult) = loadedRecords[2].item,
                  case let .image(loadedResultURL) = try XCTUnwrap(
                      loadedResult.result.content.first
                  ) else {
                return XCTFail("Nested image payloads did not round-trip through the store")
            }
            XCTAssertEqual(loadedInteractionURL.absoluteString, interactionImage.dataURLString)
            XCTAssertEqual(loadedResultURL.absoluteString, resultImage.dataURLString)

            let forbiddenPayloads = [
                interactionImage,
                resultImage,
            ].map { Data($0.data.base64EncodedString().utf8) }
            for fileURL in try regularFiles(in: fixture) where
                !fileURL.path.contains(".codexkit-state/attachments/")
            {
                let persistedData = try Data(contentsOf: fileURL)
                for forbiddenPayload in forbiddenPayloads {
                    XCTAssertNil(
                        persistedData.range(of: forbiddenPayload),
                        "Inline image data leaked into \(fileURL.lastPathComponent)"
                    )
                }
            }
        }
    }

    func testRuntimeStoresBoundImplicitHistoryPagesAndRejectOversizedPages() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let stores: [any AgentRuntimeQueryableStore] = [
            InMemoryRuntimeStateStore(),
            FileRuntimeStateStore(url: fixture.appendingPathComponent("runtime.json")),
            try SQLiteRuntimeStateStore(
                url: fixture.appendingPathComponent("runtime.sqlite"),
                importingLegacyStateFrom: fixture.appendingPathComponent("missing-sqlite.json")
            ),
            try RealmRuntimeStateStore(
                url: fixture.appendingPathComponent("runtime.realm"),
                importingLegacyStateFrom: fixture.appendingPathComponent("missing-realm.json")
            ),
        ]
        let thread = AgentThread(id: "bounded-history")
        let records = (1 ... 300).map { historyRecord(sequence: $0, threadID: thread.id) }

        for store in stores {
            try await store.apply([
                .upsertThread(thread),
                .appendHistoryItems(threadID: thread.id, items: records),
            ])

            let implicitPage = try await store.execute(HistoryItemsQuery(threadID: thread.id))
            XCTAssertEqual(implicitPage.records.count, AgentStoreLimits.defaultListResultCount)
            XCTAssertTrue(implicitPage.hasMoreBefore)

            await XCTAssertThrowsErrorAsync(try await store.execute(HistoryItemsQuery(
                threadID: thread.id,
                page: AgentQueryPage(limit: AgentStoreLimits.maximumQueryResultCount + 1)
            )))
        }
    }

    func testRuntimeStoresRejectOversizedAttachmentMessagesAtomically() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let stores: [any RuntimeStateStoring] = [
            InMemoryRuntimeStateStore(),
            FileRuntimeStateStore(url: fixture.appendingPathComponent("attachments.json")),
            try SQLiteRuntimeStateStore(
                url: fixture.appendingPathComponent("attachments.sqlite"),
                importingLegacyStateFrom: fixture.appendingPathComponent("missing-sqlite.json")
            ),
            try RealmRuntimeStateStore(
                url: fixture.appendingPathComponent("attachments.realm"),
                importingLegacyStateFrom: fixture.appendingPathComponent("missing-realm.json")
            ),
        ]
        let thread = AgentThread(id: "attachment-limit")
        let images = (0 ... AgentStoreLimits.maximumImageCountPerMessage).map { index in
            AgentImageAttachment.png(Data([UInt8(index % 255)]), id: "image-\(index)")
        }
        let message = AgentMessage(
            id: "oversized-message",
            threadID: thread.id,
            role: .user,
            text: "too many images",
            images: images
        )
        let record = AgentHistoryRecord(
            sequenceNumber: 1,
            createdAt: message.createdAt,
            item: .message(message)
        )

        for store in stores {
            await XCTAssertThrowsErrorAsync(try await store.apply([
                .upsertThread(thread),
                .appendHistoryItems(threadID: thread.id, items: [record]),
            ]))
            let preserved = try await store.loadState()
            XCTAssertTrue(preserved.threads.isEmpty)
        }
    }

    func testMemoryStoresRejectOversizedTokenQueriesBeforeReading() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let stores: [any MemoryStoring] = [
            InMemoryMemoryStore(),
            try SQLiteMemoryStore(url: fixture.appendingPathComponent("memory.sqlite")),
            try RealmMemoryStore(url: fixture.appendingPathComponent("memory.realm")),
        ]
        let text = (0 ... MemoryStoreLimits.maximumQueryTokenCount)
            .map { "token\($0)" }
            .joined(separator: " ")

        for store in stores {
            await XCTAssertThrowsErrorAsync(try await store.query(MemoryQuery(
                namespace: "bounded-query",
                text: text
            ))) { error in
                XCTAssertEqual(error as? MemoryStoreError, .invalidQuery(
                    "query text must not contain more than \(MemoryStoreLimits.maximumQueryTokenCount) distinct tokens."
                ))
            }
        }
    }

    func testDiagnosticsCardinalityFailureRollsBackEveryMemoryStore() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let stores: [any MemoryStoring] = [
            InMemoryMemoryStore(),
            try SQLiteMemoryStore(url: fixture.appendingPathComponent("diagnostics.sqlite")),
            try RealmMemoryStore(url: fixture.appendingPathComponent("diagnostics.realm")),
        ]
        let records = (0 ... MemoryStoreLimits.maximumDiagnosticDimensionValueCount).map { index in
            MemoryRecord(
                id: "record-\(index)",
                namespace: "diagnostics-limit",
                scope: "project",
                category: "category-\(index)",
                summary: "record \(index)"
            )
        }

        for store in stores {
            await XCTAssertThrowsErrorAsync(try await store.putMany(records))
            let diagnostics = try await store.diagnostics(namespace: "diagnostics-limit")
            XCTAssertEqual(diagnostics.totalRecords, 0)
            XCTAssertTrue(diagnostics.countsByCategory.isEmpty)
        }
    }

    func testRealmDiagnosticsBackfillContinuesAcrossNamespaceBatches() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let url = fixture.appendingPathComponent("backfill.realm")
        let configuration = RealmMemoryStoreConfigurationBuilder(fileURL: url).build()
        try autoreleasepool {
            let realm = try Realm(configuration: configuration)
            let builder = RealmMemoryRecordBuilder()
            let records = try (0 ..< 65).map { index in
                try builder.build(from: MemoryRecord(
                    id: "record",
                    namespace: String(format: "namespace-%03d", index),
                    scope: "project",
                    category: "fact",
                    summary: "persisted record"
                ))
            }
            try realm.write { realm.add(records) }
            realm.invalidate()
        }

        let store = try RealmMemoryStore(url: url)
        try await store.prepare()
        for index in [0, 63, 64] {
            let diagnostics = try await store.diagnostics(
                namespace: String(format: "namespace-%03d", index)
            )
            XCTAssertEqual(diagnostics.totalRecords, 1)
            XCTAssertEqual(diagnostics.countsByCategory, ["fact": 1])
        }
    }

    func testPromotionJournalIteratorReturnsBoundedBatches() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let store = RuntimeAttachmentStore(rootURL: fixture.appendingPathComponent("attachments"))
        try FileManager.default.createDirectory(
            at: store.promotionJournalDirectoryURL,
            withIntermediateDirectories: true
        )
        let keys = (0 ..< 300).map { "aa/bb/key-\($0).bin" }
        let journal = RuntimeAttachmentPromotionJournal(storageKeys: keys)
        try JSONEncoder().encode(journal).write(
            to: store.promotionJournalDirectoryURL.appendingPathComponent("journal.json")
        )

        let iterator = store.makePendingPromotionStorageKeyIterator()
        XCTAssertEqual(try iterator.nextBatch().count, 256)
        XCTAssertEqual(try iterator.nextBatch().count, 44)
        XCTAssertTrue(try iterator.nextBatch().isEmpty)
    }

    func testSnapshotReplacementRemovesOrphanedAttachmentsForPersistentStores() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let sqliteURL = fixture.appendingPathComponent("snapshot.sqlite")
        let realmURL = fixture.appendingPathComponent("snapshot.realm")
        let stores: [(any RuntimeStateStoring, URL)] = [
            (
                try SQLiteRuntimeStateStore(
                    url: sqliteURL,
                    importingLegacyStateFrom: fixture.appendingPathComponent("missing-sqlite.json")
                ),
                sqliteURL
            ),
            (
                try RealmRuntimeStateStore(
                    url: realmURL,
                    importingLegacyStateFrom: fixture.appendingPathComponent("missing-realm.json")
                ),
                realmURL
            ),
        ]

        for (store, url) in stores {
            let thread = AgentThread(id: "snapshot-attachment")
            let message = AgentMessage(
                id: "snapshot-message",
                threadID: thread.id,
                role: .user,
                text: "attachment",
                images: [.png(Data("SNAPSHOT_IMAGE".utf8), id: "snapshot-image")]
            )
            try await store.saveState(StoredRuntimeState(
                threads: [thread],
                historyByThread: [thread.id: [AgentHistoryRecord(
                    sequenceNumber: 1,
                    createdAt: message.createdAt,
                    item: .message(message)
                )]]
            ))
            let attachmentRoot = RuntimeAttachmentStore.sidecarDirectoryURL(for: url)
                .appendingPathComponent("attachments", isDirectory: true)
            XCTAssertEqual(try regularFiles(in: attachmentRoot).count, 1)

            try await store.saveState(StoredRuntimeState(threads: [thread]))
            let remainingFiles = try regularFiles(in: attachmentRoot).filter {
                !$0.lastPathComponent.hasPrefix(".codexkit-")
            }
            XCTAssertTrue(remainingFiles.isEmpty)
        }
    }

    func testPersistentThreadDeletionCleansAttachmentsInBoundedBatches() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let sqliteURL = fixture.appendingPathComponent("delete.sqlite")
        let realmURL = fixture.appendingPathComponent("delete.realm")
        let stores: [(any RuntimeStateStoring, URL)] = [
            (
                try SQLiteRuntimeStateStore(
                    url: sqliteURL,
                    importingLegacyStateFrom: fixture.appendingPathComponent("missing-sqlite.json")
                ),
                sqliteURL
            ),
            (
                try RealmRuntimeStateStore(
                    url: realmURL,
                    importingLegacyStateFrom: fixture.appendingPathComponent("missing-realm.json")
                ),
                realmURL
            ),
        ]

        for (store, url) in stores {
            let thread = AgentThread(id: "bounded-delete")
            let records = (1 ... 300).map { sequence in
                let message = AgentMessage(
                    id: "delete-message-\(sequence)",
                    threadID: thread.id,
                    role: .user,
                    text: "attachment \(sequence)",
                    images: [.png(
                        Data("DELETE_IMAGE_\(sequence)".utf8),
                        id: "delete-image-\(sequence)"
                    )]
                )
                return AgentHistoryRecord(
                    sequenceNumber: sequence,
                    createdAt: message.createdAt,
                    item: .message(message)
                )
            }
            try await store.apply([
                .upsertThread(thread),
                .appendHistoryItems(threadID: thread.id, items: records),
            ])
            let attachmentRoot = RuntimeAttachmentStore.sidecarDirectoryURL(for: url)
                .appendingPathComponent("attachments", isDirectory: true)
            XCTAssertEqual(try visibleAttachmentFiles(in: attachmentRoot).count, 300)

            try await store.apply([.deleteThread(threadID: thread.id)])

            try await waitUntil {
                try regularFiles(in: attachmentRoot).allSatisfy {
                    $0.lastPathComponent.hasPrefix(".codexkit-")
                }
            }
        }
    }

    func testRuntimeStoresRejectOversizedStructuredPayloadsAtomically() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let stores: [any RuntimeStateStoring] = [
            InMemoryRuntimeStateStore(),
            FileRuntimeStateStore(url: fixture.appendingPathComponent("payload.json")),
            try SQLiteRuntimeStateStore(
                url: fixture.appendingPathComponent("payload.sqlite"),
                importingLegacyStateFrom: fixture.appendingPathComponent("missing-sqlite.json")
            ),
            try RealmRuntimeStateStore(
                url: fixture.appendingPathComponent("payload.realm"),
                importingLegacyStateFrom: fixture.appendingPathComponent("missing-realm.json")
            ),
        ]
        let thread = AgentThread(id: "payload-limit")
        let output = AgentStructuredOutputRecord(
            threadID: thread.id,
            turnID: "payload-turn",
            metadata: AgentStructuredOutputMetadata(
                formatName: "payload",
                payload: .string(String(
                    repeating: "x",
                    count: AgentStoreLimits.maximumEmbeddedPayloadByteCount + 1
                ))
            )
        )
        let record = AgentHistoryRecord(
            sequenceNumber: 1,
            createdAt: output.committedAt,
            item: .structuredOutput(output)
        )

        for store in stores {
            await XCTAssertThrowsErrorAsync(try await store.apply([
                .upsertThread(thread),
                .appendHistoryItems(threadID: thread.id, items: [record]),
            ]))
            let preserved = try await store.loadState()
            XCTAssertTrue(preserved.threads.isEmpty)
        }
    }

    func testRuntimeStoresRejectOversizedContextRowsAtomically() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let stores: [any RuntimeStateStoring] = [
            InMemoryRuntimeStateStore(),
            FileRuntimeStateStore(url: fixture.appendingPathComponent("context.json")),
            try SQLiteRuntimeStateStore(
                url: fixture.appendingPathComponent("context.sqlite"),
                importingLegacyStateFrom: fixture.appendingPathComponent("missing-sqlite.json")
            ),
            try RealmRuntimeStateStore(
                url: fixture.appendingPathComponent("context.realm"),
                importingLegacyStateFrom: fixture.appendingPathComponent("missing-realm.json")
            ),
        ]
        let thread = AgentThread(id: "context-limit")
        let text = String(repeating: "x", count: AgentStoreLimits.maximumMessageTextByteCount)
        let messages = (0 ..< 9).map { index in
            AgentMessage(
                id: "context-message-\(index)",
                threadID: thread.id,
                role: .user,
                text: text
            )
        }
        let context = AgentThreadContextState(
            threadID: thread.id,
            effectiveMessages: messages
        )

        for store in stores {
            await XCTAssertThrowsErrorAsync(try await store.apply([
                .upsertThread(thread),
                .upsertThreadContextState(threadID: thread.id, state: context),
            ]))
            let preserved = try await store.loadState()
            XCTAssertTrue(preserved.threads.isEmpty)
        }
    }

    func testRuntimeStoresRejectRedactionsWithUnboundedDuplicateMatches() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let stores: [any RuntimeStateStoring] = [
            InMemoryRuntimeStateStore(),
            FileRuntimeStateStore(url: fixture.appendingPathComponent("redaction.json")),
            try SQLiteRuntimeStateStore(
                url: fixture.appendingPathComponent("redaction.sqlite"),
                importingLegacyStateFrom: fixture.appendingPathComponent("missing-sqlite.json")
            ),
            try RealmRuntimeStateStore(
                url: fixture.appendingPathComponent("redaction.realm"),
                importingLegacyStateFrom: fixture.appendingPathComponent("missing-realm.json")
            ),
        ]
        let thread = AgentThread(id: "redaction-limit")
        let records = (1 ... AgentStoreLimits.maximumRedactionMatchCount + 1).map { sequence in
            AgentHistoryRecord(
                id: "shared-record-id",
                sequenceNumber: sequence,
                createdAt: Date(timeIntervalSince1970: TimeInterval(sequence)),
                item: .systemEvent(AgentSystemEventRecord(
                    type: .threadResumed,
                    threadID: thread.id,
                    occurredAt: Date(timeIntervalSince1970: TimeInterval(sequence))
                ))
            )
        }

        for store in stores {
            try await store.apply([
                .upsertThread(thread),
                .appendHistoryItems(
                    threadID: thread.id,
                    items: Array(records.prefix(AgentStoreLimits.maximumHistoryWriteCount))
                ),
            ])
            try await store.apply([.appendHistoryItems(
                threadID: thread.id,
                items: Array(records.dropFirst(AgentStoreLimits.maximumHistoryWriteCount))
            )])

            await XCTAssertThrowsErrorAsync(try await store.apply([.redactHistoryItems(
                threadID: thread.id,
                itemIDs: ["shared-record-id"],
                reason: nil
            )]))

            let preserved = try await store.loadState()
            XCTAssertEqual(preserved.historyByThread[thread.id]?.count, records.count)
            XCTAssertTrue(preserved.historyByThread[thread.id]?.allSatisfy {
                $0.redaction == nil
            } ?? false)
        }
    }

    func testRuntimeStoresRemoveCompactionPreviewWhenRedactingHistory() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let stores: [any RuntimeStateStoring] = [
            InMemoryRuntimeStateStore(),
            FileRuntimeStateStore(url: fixture.appendingPathComponent("preview-redaction.json")),
            try SQLiteRuntimeStateStore(
                url: fixture.appendingPathComponent("preview-redaction.sqlite"),
                importingLegacyStateFrom: fixture.appendingPathComponent("missing-sqlite.json")
            ),
            try RealmRuntimeStateStore(
                url: fixture.appendingPathComponent("preview-redaction.realm"),
                importingLegacyStateFrom: fixture.appendingPathComponent("missing-realm.json")
            ),
        ]
        let thread = AgentThread(id: "compaction-preview-redaction")
        let record = AgentHistoryRecord(
            id: "compaction-record",
            sequenceNumber: 1,
            createdAt: Date(timeIntervalSince1970: 1),
            item: .systemEvent(AgentSystemEventRecord(
                type: .contextCompacted,
                threadID: thread.id,
                compaction: AgentContextCompactionMarker(
                    generation: 2,
                    reason: .manual,
                    effectiveMessageCountBefore: 12,
                    effectiveMessageCountAfter: 3,
                    debugSummaryPreview: "Sensitive summary text"
                ),
                occurredAt: Date(timeIntervalSince1970: 1)
            ))
        )

        for store in stores {
            try await store.apply([
                .upsertThread(thread),
                .appendHistoryItems(threadID: thread.id, items: [record]),
            ])
            try await store.apply([.redactHistoryItems(
                threadID: thread.id,
                itemIDs: [record.id],
                reason: .init(code: "privacy")
            )])

            let state = try await store.loadState()
            let redacted = try XCTUnwrap(state.historyByThread[thread.id]?.first)
            XCTAssertNotNil(redacted.redaction)
            guard case let .systemEvent(event) = redacted.item,
                  let marker = event.compaction else {
                return XCTFail("Expected the redacted compaction marker to remain available.")
            }
            XCTAssertEqual(marker.generation, 2)
            XCTAssertEqual(marker.reason, .manual)
            XCTAssertEqual(marker.effectiveMessageCountBefore, 12)
            XCTAssertEqual(marker.effectiveMessageCountAfter, 3)
            XCTAssertNil(marker.debugSummaryPreview)
        }
    }

    func testPersistentMemoryStoresRejectCorruptCollectionsAndProjections() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let record = MemoryRecord(
            id: "bounded-child-record",
            namespace: "hardening",
            scope: "project",
            category: "fact",
            summary: "bounded child collections"
        )
        let projectionRecord = MemoryRecord(
            id: "projection-record",
            namespace: record.namespace,
            scope: "project",
            category: "fact",
            summary: "validated projections"
        )

        let sqliteURL = fixture.appendingPathComponent("corrupt-children.sqlite")
        let sqliteStore = try SQLiteMemoryStore(url: sqliteURL)
        try await sqliteStore.putMany([record, projectionRecord])
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(sqliteURL.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        let sqliteResult = sqlite3_exec(
            database,
            """
            WITH RECURSIVE ordinal(value) AS (
                SELECT 0
                UNION ALL
                SELECT value + 1 FROM ordinal WHERE value < 32
            )
            INSERT INTO memory_evidence(namespace, record_id, ordinal, value)
            SELECT 'hardening', 'bounded-child-record', value, 'corrupt' FROM ordinal
            """,
            nil,
            nil,
            nil
        )
        XCTAssertEqual(sqliteResult, SQLITE_OK)
        await XCTAssertThrowsErrorAsync(
            try await sqliteStore.record(id: record.id, namespace: record.namespace)
        )
        XCTAssertEqual(sqlite3_exec(
            database,
            "UPDATE memory_records SET rendered_character_count = 0 WHERE id = 'projection-record'",
            nil,
            nil,
            nil
        ), SQLITE_OK)
        await XCTAssertThrowsErrorAsync(
            try await sqliteStore.record(
                id: projectionRecord.id,
                namespace: projectionRecord.namespace
            )
        )

        let realmURL = fixture.appendingPathComponent("corrupt-children.realm")
        let realmStore = try RealmMemoryStore(url: realmURL)
        try await realmStore.putMany([record, projectionRecord])
        try autoreleasepool {
            let realm = try Realm(
                configuration: RealmMemoryStoreConfigurationBuilder(fileURL: realmURL).build()
            )
            let object = try XCTUnwrap(realm.object(
                ofType: RealmMemoryRecord.self,
                forPrimaryKey: RealmMemoryKey.make(namespace: record.namespace, id: record.id)
            ))
            try realm.write {
                object.evidence.append(
                    objectsIn: Array(
                        repeating: "corrupt",
                        count: MemoryStoreLimits.maximumEvidenceCount + 1
                    )
                )
                realm.object(
                    ofType: RealmMemoryRecord.self,
                    forPrimaryKey: RealmMemoryKey.make(
                        namespace: projectionRecord.namespace,
                        id: projectionRecord.id
                    )
                )?.renderedCharacterCount = 0
            }
            realm.invalidate()
        }
        // Read the corrupt persisted data through a fresh actor-bound Realm. The original
        // cached reader advances via notifications and can still expose its pre-corruption
        // snapshot here; notification scheduling is not what this validation test exercises.
        let corruptedRealmStore = try RealmMemoryStore(url: realmURL)
        await XCTAssertThrowsErrorAsync(
            try await corruptedRealmStore.record(id: record.id, namespace: record.namespace)
        )
        await XCTAssertThrowsErrorAsync(
            try await corruptedRealmStore.record(
                id: projectionRecord.id,
                namespace: projectionRecord.namespace
            )
        )
    }

    func testMemoryStoresRejectOversizedAggregateBulkPayloadsAtomically() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let records = (0 ..< MemoryStoreLimits.maximumBulkRecordCount).map { index in
            MemoryRecord(
                id: "bulk-\(index)",
                namespace: "bulk-limit",
                scope: "project",
                category: "fact",
                summary: "bounded bulk record",
                evidence: ["evidence"],
                tags: Array(
                    repeating: "tag",
                    count: MemoryStoreLimits.maximumTagCount
                )
            )
        }
        let stores: [any MemoryStoring] = [
            InMemoryMemoryStore(),
            try SQLiteMemoryStore(url: fixture.appendingPathComponent("bulk.sqlite")),
            try RealmMemoryStore(url: fixture.appendingPathComponent("bulk.realm")),
        ]

        for store in stores {
            await XCTAssertThrowsErrorAsync(try await store.putMany(records))
            let diagnostics = try await store.diagnostics(namespace: "bulk-limit")
            XCTAssertEqual(diagnostics.totalRecords, 0)
        }
    }

    func testRuntimeQueryPayloadBudgetRejectsAggregateDecodeBursts() throws {
        let maximumPayload = Data(
            repeating: 0,
            count: AgentStoreLimits.maximumPersistedPayloadByteCount
        )
        var total = 0
        let payloadCount = AgentStoreLimits.maximumMaterializedPayloadByteCount
            / AgentStoreLimits.maximumPersistedPayloadByteCount
        for _ in 0 ..< payloadCount {
            try AgentStoreLimitValidator.accumulateMaterializedPayload(
                maximumPayload,
                name: "query fixture",
                total: &total
            )
        }
        XCTAssertThrowsError(try AgentStoreLimitValidator.accumulateMaterializedPayload(
            Data([0]),
            name: "query fixture",
            total: &total
        ))
    }

    private func makeFixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexKitHardening-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func historyRecord(sequence: Int, threadID: String) -> AgentHistoryRecord {
        let message = AgentMessage(
            id: "message-\(sequence)",
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

    private func visibleAttachmentFiles(in root: URL) throws -> [URL] {
        try regularFiles(in: root).filter {
            !$0.lastPathComponent.hasPrefix(".codexkit-")
        }
    }
}
