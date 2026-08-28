import CodexKit
@testable import CodexKitRealm
import CodexKitSQLite
import Foundation
import RealmSwift
import XCTest

final class RealmStoreTests: XCTestCase {
    func testRealmRuntimeStorePersistsAndReloadsState() async throws {
        let directory = try makeTemporaryRealmDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("runtime.realm")
        let imageData = Data("CODEXKIT_IMAGE_BYTES_MUST_STAY_ON_DISK_REALM".utf8)
        let thread = AgentThread(id: "realm-thread", title: "Realm")
        let message = AgentMessage(
            id: "realm-message",
            threadID: thread.id,
            role: .assistant,
            text: "Persisted in Realm",
            images: [.png(imageData, id: "realm-image")]
        )
        let history = AgentHistoryRecord(
            sequenceNumber: 1,
            createdAt: message.createdAt,
            item: .message(message)
        )
        let context = AgentThreadContextState(
            threadID: thread.id,
            effectiveMessages: [message],
            generation: 2
        )
        let state = StoredRuntimeState(
            threads: [thread],
            historyByThread: [thread.id: [history]],
            contextStateByThread: [thread.id: context]
        )

        let store = try RealmRuntimeStateStore(url: url)
        let metadata = try await store.prepare()
        XCTAssertEqual(metadata.storeKind, "RealmRuntimeStateStore")
        XCTAssertTrue(metadata.capabilities.supportsMigrations)
        XCTAssertTrue(metadata.capabilities.supportsPushdownQueries)
        try await store.saveState(state)

        let reopened = try RealmRuntimeStateStore(url: url)
        let loaded = try await reopened.loadState()
        XCTAssertEqual(loaded.threads, state.threads)
        XCTAssertEqual(loaded.historyByThread[thread.id], [history])
        XCTAssertEqual(loaded.contextStateByThread[thread.id], context)
        let persistedThreads = try await reopened.execute(ThreadMetadataQuery())
        XCTAssertEqual(persistedThreads.map(\.id), [thread.id])
        let loadedSummary = try await reopened.fetchThreadSummary(id: thread.id)
        XCTAssertEqual(loadedSummary.threadID, thread.id)
        try autoreleasepool {
            let realm = try Realm(configuration: Realm.Configuration(
                fileURL: url,
                schemaVersion: RealmRuntimeSchema.version,
                objectTypes: RealmRuntimeSchema.objectTypes
            ))
            let historyObject = try XCTUnwrap(realm.objects(RealmRuntimeHistoryObject.self).first)
            let contextObject = try XCTUnwrap(realm.objects(RealmRuntimeContextObject.self).first)
            for encodedValue in [historyObject.encodedRecord, contextObject.encodedState] {
                XCTAssertNil(encodedValue.range(of: imageData))
                XCTAssertNil(encodedValue.range(of: imageData.base64EncodedData()))
            }
            realm.invalidate()
        }
        XCTAssertNil(try Data(contentsOf: url).range(of: imageData))
        XCTAssertNil(try Data(contentsOf: url).range(of: imageData.base64EncodedData()))
    }

    func testRealmPromotionFailureKeepsARepairedReferencedAttachment() async throws {
        let directory = try makeTemporaryRealmDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("promotion-failure.realm")
        let orderedThreadIDs = ["repair-thread", "blocked-thread"].sorted {
            RuntimeAttachmentStore.safePathComponent($0)
                < RuntimeAttachmentStore.safePathComponent($1)
        }
        let repairedThread = AgentThread(id: orderedThreadIDs[0])
        let blockedThread = AgentThread(id: orderedThreadIDs[1])
        let repairedData = Data("REALM_REPAIRED_ATTACHMENT".utf8)
        let repairedMessage = AgentMessage(
            id: "repaired-message",
            threadID: repairedThread.id,
            role: .assistant,
            text: "repair",
            images: [.png(repairedData, id: "repaired-image")]
        )
        let store = try RealmRuntimeStateStore(url: url)
        try await store.apply([
            .upsertThread(repairedThread),
            .appendHistoryItems(
                threadID: repairedThread.id,
                items: [AgentHistoryRecord(
                    sequenceNumber: 1,
                    createdAt: repairedMessage.createdAt,
                    item: .message(repairedMessage)
                )]
            ),
        ])

        let attachmentRoot = RuntimeAttachmentStore.sidecarDirectoryURL(for: url)
            .appendingPathComponent("attachments", isDirectory: true)
        let repairedURL = try XCTUnwrap(try regularFiles(in: attachmentRoot).first)
        try Data("CORRUPTED".utf8).write(to: repairedURL, options: .atomic)
        let blockedThreadDirectory = attachmentRoot.appendingPathComponent(
            RuntimeAttachmentStore.safePathComponent(blockedThread.id),
            isDirectory: true
        )
        try Data("not-a-directory".utf8).write(to: blockedThreadDirectory)
        let blockedMessage = AgentMessage(
            id: "blocked-message",
            threadID: blockedThread.id,
            role: .assistant,
            text: "blocked",
            images: [.png(Data("BLOCKED_ATTACHMENT".utf8), id: "blocked-image")]
        )

        await XCTAssertThrowsErrorAsync(try await store.apply([
            .upsertThreadContextState(
                threadID: repairedThread.id,
                state: AgentThreadContextState(
                    threadID: repairedThread.id,
                    effectiveMessages: [repairedMessage]
                )
            ),
            .upsertThread(blockedThread),
            .appendHistoryItems(
                threadID: blockedThread.id,
                items: [AgentHistoryRecord(
                    sequenceNumber: 1,
                    createdAt: blockedMessage.createdAt,
                    item: .message(blockedMessage)
                )]
            ),
        ]))

        XCTAssertEqual(try Data(contentsOf: repairedURL), repairedData)
        let loaded = try await store.loadState()
        XCTAssertEqual(loaded.historyByThread[repairedThread.id]?.first?.item, .message(repairedMessage))
        XCTAssertNil(loaded.historyByThread[blockedThread.id])
    }

    func testRealmRuntimeStoreAppliesIncrementalOperationsThroughContract() async throws {
        let directory = try makeTemporaryRealmDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("runtime.realm")
        let store = try RealmRuntimeStateStore(url: url)
        let thread = AgentThread(id: "realm-operations")
        let message = AgentMessage(threadID: thread.id, role: .user, text: "Hello Realm")
        let history = AgentHistoryRecord(
            sequenceNumber: 1,
            createdAt: message.createdAt,
            item: .message(message)
        )

        try await store.apply([
            .upsertThread(thread),
            .appendHistoryItems(threadID: thread.id, items: [history]),
        ])

        let loaded = try await store.loadState()
        XCTAssertEqual(loaded.threads.map(\.id), [thread.id])
        XCTAssertEqual(loaded.historyByThread[thread.id], [history])

        try await store.apply([.deleteThread(threadID: thread.id)])
        let deletedState = try await store.loadState()
        XCTAssertTrue(deletedState.threads.isEmpty)
    }

    func testRealmRuntimeActivationUsesBoundedHistoryAndPersistedSequence() async throws {
        let directory = try makeTemporaryRealmDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("runtime.realm")
        let store = try RealmRuntimeStateStore(url: url)
        let thread = AgentThread(id: "realm-activation")
        let records = (1 ... 6).map { sequence in
            let role: AgentRole = sequence.isMultiple(of: 2) ? .assistant : .user
            let message = AgentMessage(
                id: "message-\(sequence)",
                threadID: thread.id,
                role: role,
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

        let activation = try await store.loadThreadActivationState(
            id: thread.id,
            policy: AgentThreadActivationPolicy(
                maximumMessageCount: 2,
                maximumEstimatedTokens: 100,
                maximumHistoryRecordCount: 2
            )
        )

        XCTAssertEqual(activation.nextHistorySequence, 7)
        XCTAssertEqual(activation.effectiveMessages.map(\.text), ["message 5", "message 6"])
        try autoreleasepool {
            let realm = try Realm(configuration: RealmRuntimeStoreConfigurationBuilder(
                fileURL: url
            ).build())
            XCTAssertEqual(
                realm.object(
                    ofType: RealmRuntimeThreadObject.self,
                    forPrimaryKey: thread.id
                )?.nextHistorySequence,
                7
            )
            realm.invalidate()
        }
    }

    func testPersistentActivationNeverHydratesHalfAHistoryRelationship() async throws {
        let directory = try makeTemporaryRealmDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stores: [any RuntimeStateStoring] = [
            try SQLiteRuntimeStateStore(url: directory.appendingPathComponent("relation.sqlite")),
            try RealmRuntimeStateStore(url: directory.appendingPathComponent("relation.realm")),
        ]

        for (index, store) in stores.enumerated() {
            let thread = AgentThread(id: "relationship-boundary-\(index)")
            let user = AgentMessage(
                id: "user",
                threadID: thread.id,
                role: .user,
                text: "Create a status payload",
                createdAt: Date(timeIntervalSince1970: 1)
            )
            let assistant = AgentMessage(
                id: "assistant",
                threadID: thread.id,
                role: .assistant,
                text: "Ready",
                createdAt: Date(timeIntervalSince1970: 2)
            )
            let metadata = AgentStructuredOutputMetadata(
                formatName: "status",
                payload: .object(["ready": .bool(true)])
            )
            let history = [
                AgentHistoryRecord(sequenceNumber: 1, createdAt: user.createdAt, item: .message(user)),
                AgentHistoryRecord(sequenceNumber: 2, createdAt: assistant.createdAt, item: .message(assistant)),
                AgentHistoryRecord(
                    sequenceNumber: 3,
                    createdAt: assistant.createdAt,
                    item: .structuredOutput(AgentStructuredOutputRecord(
                        threadID: thread.id,
                        turnID: "turn",
                        messageID: assistant.id,
                        metadata: metadata,
                        committedAt: assistant.createdAt
                    ))
                ),
            ]
            try await store.saveState(StoredRuntimeState(
                threads: [thread],
                historyByThread: [thread.id: history]
            ))

            let cut = try await store.loadThreadActivationState(
                id: thread.id,
                policy: .init(
                    maximumMessageCount: 4,
                    maximumEstimatedTokens: 200,
                    maximumHistoryRecordCount: 1
                )
            )
            XCTAssertTrue(cut.effectiveMessages.isEmpty)

            let complete = try await store.loadThreadActivationState(
                id: thread.id,
                policy: .init(
                    maximumMessageCount: 4,
                    maximumEstimatedTokens: 200,
                    maximumHistoryRecordCount: 3
                )
            )
            XCTAssertEqual(complete.effectiveMessages.map(\.text), [user.text, assistant.text])
            XCTAssertEqual(complete.effectiveMessages.last?.structuredOutput, metadata)
        }
    }

    func testRealmRuntimeStoreRejectsNonMonotonicHistoryWithoutPartialWrite() async throws {
        let directory = try makeTemporaryRealmDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("runtime.realm")
        let store = try RealmRuntimeStateStore(url: url)
        let thread = AgentThread(id: "realm-sequence")
        try await store.apply([.upsertThread(thread)])
        let message = AgentMessage(
            threadID: thread.id,
            role: .user,
            text: "Out of sequence",
            images: [.png(Data("UNCOMMITTED_REALM_IMAGE".utf8))]
        )
        let record = AgentHistoryRecord(
            sequenceNumber: 2,
            createdAt: message.createdAt,
            item: .message(message)
        )

        do {
            try await store.apply([.appendHistoryItems(threadID: thread.id, items: [record])])
            XCTFail("Expected an invalid history sequence error")
        } catch let error as AgentRuntimeError {
            XCTAssertEqual(error.code, "invalid_history_sequence")
        }

        let loaded = try await store.loadState()
        XCTAssertEqual(loaded.threads.map(\.id), [thread.id])
        XCTAssertTrue(loaded.historyByThread[thread.id, default: []].isEmpty)
        let attachmentRoot = directory
            .appendingPathComponent("\(url.lastPathComponent).codexkit-state", isDirectory: true)
            .appendingPathComponent("attachments", isDirectory: true)
        XCTAssertTrue(try regularFiles(in: attachmentRoot).isEmpty)
    }

    func testRealmRedactionRemovesOnlyCommittedAttachmentsAndCachedContext() async throws {
        let directory = try makeTemporaryRealmDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("runtime.realm")
        let store = try RealmRuntimeStateStore(url: url)
        let thread = AgentThread(id: "realm-redaction")
        let message = AgentMessage(
            id: "sensitive-message",
            threadID: thread.id,
            role: .user,
            text: "sensitive",
            images: [.png(Data([0x89, 0x50, 0x4E, 0x47]))]
        )
        let record = AgentHistoryRecord(
            id: "sensitive-record",
            sequenceNumber: 1,
            createdAt: message.createdAt,
            item: .message(message)
        )
        let retainedMessage = AgentMessage(
            id: "retained-message",
            threadID: thread.id,
            role: .assistant,
            text: "retain",
            images: [.png(Data([0x01, 0x02]))]
        )
        let retainedRecord = AgentHistoryRecord(
            id: "retained-record",
            sequenceNumber: 2,
            createdAt: retainedMessage.createdAt,
            item: .message(retainedMessage)
        )
        try await store.saveState(StoredRuntimeState(
            threads: [thread],
            historyByThread: [thread.id: [record, retainedRecord]],
            contextStateByThread: [thread.id: AgentThreadContextState(
                threadID: thread.id,
                effectiveMessages: [message, retainedMessage]
            )]
        ))
        let attachmentsDirectory = directory
            .appendingPathComponent("runtime.realm.codexkit-state", isDirectory: true)
            .appendingPathComponent("attachments", isDirectory: true)
        XCTAssertEqual(try regularFiles(in: attachmentsDirectory).count, 2)

        try await store.apply([.redactHistoryItems(
            threadID: thread.id,
            itemIDs: [record.id],
            reason: AgentRedactionReason(code: "user_requested")
        )])

        XCTAssertEqual(try regularFiles(in: attachmentsDirectory).count, 1)
        let contextState = try await store.fetchThreadContextState(id: thread.id)
        XCTAssertNil(contextState)
        let redacted = try await store.execute(HistoryItemsQuery(threadID: thread.id))
        XCTAssertNotNil(redacted.records.first?.redaction)
        guard case let .message(redactedMessage) = redacted.records.first?.item,
              case let .message(loadedRetainedMessage) = redacted.records.last?.item
        else {
            return XCTFail("Expected the redacted message record.")
        }
        XCTAssertTrue(redactedMessage.images.isEmpty)
        XCTAssertEqual(loadedRetainedMessage.images.first?.data, retainedMessage.images.first?.data)
    }

    func testRealmMemoryStorePersistsQueriesAndMutations() async throws {
        let directory = try makeTemporaryRealmDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("memory.realm")
        let record = MemoryRecord(
            id: "realm-memory",
            namespace: "assistant",
            scope: "feature:realm",
            category: "preference",
            summary: "Prefer Realm persistence",
            evidence: ["The user selected Realm."],
            importance: 0.9,
            tags: ["realm"],
            dedupeKey: "database-choice"
        )

        let store = try RealmMemoryStore(url: url)
        try await store.put(record)
        let result = try await store.query(
            MemoryQuery(namespace: "assistant", text: "Realm")
        )
        XCTAssertEqual(result.matches.first?.record.id, record.id)

        let reopened = try RealmMemoryStore(url: url)
        let reopenedRecord = try await reopened.record(id: record.id, namespace: "assistant")
        XCTAssertEqual(reopenedRecord, record)
        try await reopened.archive(ids: [record.id], namespace: "assistant")
        let activeRecords = try await reopened.list(namespace: "assistant")
        let allRecords = try await reopened.list(namespace: "assistant", includeArchived: true)
        XCTAssertTrue(activeRecords.isEmpty)
        XCTAssertEqual(allRecords.map(\.id), [record.id])
    }

    func testRealmMemoryCompositeKeysCannotAlias() async throws {
        let directory = try makeTemporaryRealmDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try RealmMemoryStore(url: directory.appendingPathComponent("memory.realm"))
        let records = [
            MemoryRecord(
                id: "c",
                namespace: "a\u{1F}b",
                scope: "test",
                category: "fact",
                summary: "first"
            ),
            MemoryRecord(
                id: "b\u{1F}c",
                namespace: "a",
                scope: "test",
                category: "fact",
                summary: "second"
            ),
        ]
        try await store.putMany(records)
        let first = try await store.record(id: records[0].id, namespace: records[0].namespace)
        let second = try await store.record(id: records[1].id, namespace: records[1].namespace)
        XCTAssertEqual(first, records[0])
        XCTAssertEqual(second, records[1])
    }

    func testRealmMemoryDedupeClaimIsAtomicAcrossStoreInstances() async throws {
        let directory = try makeTemporaryRealmDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("memory.realm")
        let firstStore = try RealmMemoryStore(url: url)
        let secondStore = try RealmMemoryStore(url: url)
        let records = ["first", "second"].map { id in
            MemoryRecord(
                id: id,
                namespace: "assistant",
                scope: "test",
                category: "fact",
                summary: id,
                dedupeKey: "shared-dedupe"
            )
        }

        async let firstError = Self.memoryPutError(store: firstStore, record: records[0])
        async let secondError = Self.memoryPutError(store: secondStore, record: records[1])
        let errors = await [firstError, secondError]
        XCTAssertEqual(errors.filter { $0 == nil }.count, 1)
        XCTAssertEqual(
            errors.compactMap { $0 }.filter { $0 == .duplicateDedupeKey("shared-dedupe") }.count,
            1
        )
        let stored = try await firstStore.list(namespace: "assistant")
        XCTAssertEqual(stored.count, 1)
    }

    func testRealmMemoryPutManyRejectsStoredCollisionsAtomically() async throws {
        let directory = try makeTemporaryRealmDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try RealmMemoryStore(url: directory.appendingPathComponent("memory.realm"))
        let existing = MemoryRecord(
            id: "existing",
            namespace: "assistant",
            scope: "user",
            category: "fact",
            summary: "existing",
            dedupeKey: "claimed"
        )
        try await store.put(existing)

        await XCTAssertThrowsErrorAsync(try await store.putMany([
            MemoryRecord(
                id: "new-before-id-collision",
                namespace: "assistant",
                scope: "thread",
                category: "transient",
                summary: "must roll back"
            ),
            MemoryRecord(
                id: existing.id,
                namespace: existing.namespace,
                scope: "thread",
                category: "transient",
                summary: "duplicate ID"
            ),
        ])) { error in
            XCTAssertEqual(error as? MemoryStoreError, .duplicateRecordID(existing.id))
        }

        await XCTAssertThrowsErrorAsync(try await store.putMany([
            MemoryRecord(
                id: "new-before-dedupe-collision",
                namespace: "assistant",
                scope: "thread",
                category: "transient",
                summary: "must roll back"
            ),
            MemoryRecord(
                id: "dedupe-collision",
                namespace: "assistant",
                scope: "thread",
                category: "transient",
                summary: "duplicate dedupe key",
                dedupeKey: "claimed"
            ),
        ])) { error in
            XCTAssertEqual(error as? MemoryStoreError, .duplicateDedupeKey("claimed"))
        }

        let records = try await store.list(namespace: "assistant", includeArchived: true)
        XCTAssertEqual(records, [existing])
        let diagnostics = try await store.diagnostics(namespace: "assistant")
        XCTAssertEqual(diagnostics.totalRecords, 1)
        XCTAssertEqual(diagnostics.activeRecords, 1)
        XCTAssertEqual(diagnostics.countsByScope, ["user": 1])
        XCTAssertEqual(diagnostics.countsByCategory, ["fact": 1])
    }

    func testRealmLegacyImportRetriesAfterFailedImport() async throws {
        let directory = try makeTemporaryRealmDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let realmURL = directory.appendingPathComponent("runtime.realm")
        let legacyURL = directory.appendingPathComponent("runtime.json")
        try Data("invalid legacy state".utf8).write(to: legacyURL)
        let initiallyEmpty = try RealmRuntimeStateStore(
            url: realmURL,
            importingLegacyStateFrom: legacyURL
        )
        await XCTAssertThrowsErrorAsync(try await initiallyEmpty.prepare())

        let thread = AgentThread(id: "realm-retry-import")
        try await FileRuntimeStateStore(url: legacyURL).saveState(
            StoredRuntimeState(threads: [thread])
        )
        let retried = try RealmRuntimeStateStore(
            url: realmURL,
            importingLegacyStateFrom: legacyURL
        )
        let loaded = try await retried.loadState()
        XCTAssertEqual(loaded.threads, [thread])
    }

    func testSQLiteAndRealmUseIndependentAttachmentSidecars() async throws {
        let directory = try makeTemporaryRealmDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sqliteURL = directory.appendingPathComponent("runtime.sqlite")
        let realmURL = directory.appendingPathComponent("runtime.realm")
        let sqlite = try SQLiteRuntimeStateStore(url: sqliteURL)
        let realm = try RealmRuntimeStateStore(url: realmURL)

        let sqliteState = attachmentState(threadID: "sqlite-thread", byte: 1)
        let realmState = attachmentState(threadID: "realm-thread", byte: 2)
        try await sqlite.saveState(sqliteState)
        try await realm.saveState(realmState)

        let sqliteAttachments = directory
            .appendingPathComponent("runtime.sqlite.codexkit-state", isDirectory: true)
            .appendingPathComponent("attachments", isDirectory: true)
        let realmAttachments = directory
            .appendingPathComponent("runtime.realm.codexkit-state", isDirectory: true)
            .appendingPathComponent("attachments", isDirectory: true)
        XCTAssertEqual(try regularFiles(in: sqliteAttachments).count, 1)
        XCTAssertEqual(try regularFiles(in: realmAttachments).count, 1)

        try await sqlite.apply([.deleteThread(threadID: "sqlite-thread")])
        XCTAssertTrue(try regularFiles(in: sqliteAttachments).isEmpty)
        let loadedRealm = try await realm.loadState()
        guard case let .message(message) = loadedRealm.historyByThread["realm-thread"]?.first?.item else {
            return XCTFail("Expected the Realm attachment to remain readable.")
        }
        XCTAssertEqual(message.images.first?.data, Data([2]))
        XCTAssertEqual(try regularFiles(in: realmAttachments).count, 1)
    }

    func testRealmRuntimeStoreSerializesAttachmentMutationsAcrossInstances() async throws {
        let directory = try makeTemporaryRealmDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("concurrent-runtime.realm")
        try await assertConcurrentAttachmentMutationSafety(
            first: RealmRuntimeStateStore(url: url),
            second: RealmRuntimeStateStore(url: url)
        )
    }

    func testSQLiteRuntimeStoreSerializesAttachmentMutationsAcrossInstances() async throws {
        let directory = try makeTemporaryRealmDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("concurrent-runtime.sqlite")
        try await assertConcurrentAttachmentMutationSafety(
            first: SQLiteRuntimeStateStore(url: url),
            second: SQLiteRuntimeStateStore(url: url)
        )
    }

    func testFileRuntimeStoreSerializesAttachmentMutationsAcrossInstances() async throws {
        let directory = try makeTemporaryRealmDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("concurrent-runtime.json")
        try await assertConcurrentAttachmentMutationSafety(
            first: FileRuntimeStateStore(url: url),
            second: FileRuntimeStateStore(url: url)
        )
    }

    func testHistorySortAndCursorSemanticsMatchEveryRuntimeStore() async throws {
        let directory = try makeTemporaryRealmDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await assertHistoryQueryParity(store: InMemoryRuntimeStateStore())
        try await assertHistoryQueryParity(
            store: FileRuntimeStateStore(url: directory.appendingPathComponent("runtime.json"))
        )
        try await assertHistoryQueryParity(
            store: SQLiteRuntimeStateStore(url: directory.appendingPathComponent("runtime.sqlite"))
        )
        try await assertHistoryQueryParity(
            store: RealmRuntimeStateStore(url: directory.appendingPathComponent("runtime.realm"))
        )
    }

    func testRealmRuntimeStoreBoundsHistoryDecodingForAppendAndPagedQueries() async throws {
        let directory = try makeTemporaryRealmDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try RealmRuntimeStateStore(url: directory.appendingPathComponent("runtime.realm"))
        let thread = AgentThread(id: "realm-large-history")
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

        await store.resetPerformanceDiagnostics()
        let appendedMessage = AgentMessage(
            id: "message-1001",
            threadID: thread.id,
            role: .user,
            text: "message 1001",
            createdAt: Date(timeIntervalSince1970: 1_001)
        )
        try await store.apply([.appendHistoryItems(
            threadID: thread.id,
            items: [AgentHistoryRecord(
                sequenceNumber: 1_001,
                createdAt: appendedMessage.createdAt,
                item: .message(appendedMessage)
            )]
        )])
        var metrics = await store.performanceDiagnostics()
        XCTAssertEqual(metrics.applyDecodedHistoryRecordCount, 0)

        let page = try await store.fetchThreadHistory(
            id: thread.id,
            query: AgentHistoryQuery(limit: 10, direction: .backward)
        )
        XCTAssertEqual(page.items.count, 10)
        metrics = await store.performanceDiagnostics()
        XCTAssertEqual(metrics.queryDecodedHistoryRecordCount, 10)

        let genericPage = try await store.execute(HistoryItemsQuery(
            threadID: thread.id,
            page: AgentQueryPage(limit: 7)
        ))
        XCTAssertEqual(genericPage.records.count, 7)
        metrics = await store.performanceDiagnostics()
        XCTAssertEqual(metrics.queryDecodedHistoryRecordCount, 7)

        await store.resetPerformanceDiagnostics()
        try await store.apply([.redactHistoryItems(
            threadID: thread.id,
            itemIDs: [records[0].id],
            reason: AgentRedactionReason(code: "performance-test")
        )])
        metrics = await store.performanceDiagnostics()
        XCTAssertEqual(metrics.applyDecodedHistoryRecordCount, 2)
        let summary = try await store.fetchThreadSummary(id: thread.id)
        XCTAssertEqual(summary.itemCount, 1_001)
        XCTAssertEqual(summary.latestAssistantMessagePreview, "message 1000")
    }

    func testRealmMemoryQueryPushesStructuralFiltersBeforeMaterializingRecords() async throws {
        let directory = try makeTemporaryRealmDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try RealmMemoryStore(url: directory.appendingPathComponent("memory.realm"))
        let now = Date()
        let mismatches = (0 ..< 100).map { index in
            MemoryRecord(
                id: "mismatch-\(index)",
                namespace: "assistant",
                scope: "other",
                category: "other",
                summary: "not selected",
                importance: 0.1,
                createdAt: now,
                tags: ["other"],
                relatedIDs: ["other"]
            )
        }
        let match = MemoryRecord(
            id: "selected",
            namespace: "assistant",
            scope: "project",
            category: "preference",
            summary: "Realm filters this candidate",
            importance: 0.9,
            createdAt: now,
            tags: ["realm"],
            relatedIDs: ["thread-1"]
        )
        try await store.putMany(mismatches + [match])

        await store.resetPerformanceDiagnostics()
        let result = try await store.query(MemoryQuery(
            namespace: "assistant",
            scopes: ["project"],
            categories: ["preference"],
            tags: ["realm"],
            relatedIDs: ["thread-1"],
            recencyWindow: 60,
            minImportance: 0.8
        ))

        XCTAssertEqual(result.matches.map(\.record.id), [match.id])
        let materializedRecordCount = await store.performanceDiagnostics()
        XCTAssertEqual(materializedRecordCount, 1)
        await XCTAssertThrowsErrorAsync(try await store.list(
            MemoryRecordListQuery(namespace: "assistant", limit: -1)
        ))
    }

    func testRealmMemoryRanksAndLimitsLargeCandidateSetsBeforeMaterializingRecords() async throws {
        let directory = try makeTemporaryRealmDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try RealmMemoryStore(url: directory.appendingPathComponent("memory.realm"))
        let timestamp = Date()
        let records = (0 ..< 250).map { index in
            MemoryRecord(
                id: String(format: "candidate-%03d", index),
                namespace: "assistant",
                scope: "project",
                category: "fact",
                summary: "shared database-ranked candidate",
                importance: Double(index) / 250,
                createdAt: timestamp
            )
        }
        for start in stride(
            from: 0,
            to: records.count,
            by: MemoryStoreLimits.maximumBulkRecordCount
        ) {
            let end = min(start + MemoryStoreLimits.maximumBulkRecordCount, records.count)
            try await store.putMany(Array(records[start ..< end]))
        }

        await store.resetPerformanceDiagnostics()
        let result = try await store.query(MemoryQuery(
            namespace: "assistant",
            scopes: ["project"],
            text: "shared database ranked",
            limit: 5,
            maxCharacters: 10_000
        ))

        XCTAssertEqual(result.matches.map(\.record.id), [
            "candidate-249",
            "candidate-248",
            "candidate-247",
            "candidate-246",
            "candidate-245",
        ])
        XCTAssertTrue(result.truncated)
        let materializedRecordCount = await store.performanceDiagnostics()
        XCTAssertEqual(materializedRecordCount, 5)
    }

    func testRealmMemoryRankingCursorSkipsOversizedRowsInsideRealm() async throws {
        let directory = try makeTemporaryRealmDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try RealmMemoryStore(url: directory.appendingPathComponent("memory.realm"))
        let timestamp = Date(timeIntervalSince1970: 100)
        let oversized = (0 ..< 20).map { index in
            MemoryRecord(
                id: String(format: "oversized-%02d", index),
                namespace: "assistant",
                scope: "project",
                category: "fact",
                summary: String(repeating: "oversized ", count: 40),
                importance: 0.8 - (Double(index) / 100),
                createdAt: timestamp
            )
        }
        let first = MemoryRecord(
            id: "first",
            namespace: "assistant",
            scope: "project",
            category: "fact",
            summary: "first ranked memory",
            importance: 1,
            createdAt: timestamp
        )
        let fitting = MemoryRecord(
            id: "fitting",
            namespace: "assistant",
            scope: "project",
            category: "fact",
            summary: "small",
            importance: 0.1,
            createdAt: timestamp
        )
        try await store.putMany([first] + oversized + [fitting])

        let firstPage = try await store.query(MemoryQuery(
            namespace: "assistant",
            limit: 1,
            maxCharacters: 10_000
        ))
        let cursor = try XCTUnwrap(firstPage.nextCursor)
        await store.resetPerformanceDiagnostics()
        let nextPage = try await store.query(MemoryQuery(
            namespace: "assistant",
            limit: 1,
            maxCharacters: 100,
            cursor: cursor
        ))

        XCTAssertEqual(nextPage.matches.map(\.record.id), [fitting.id])
        let materializedRecordCount = await store.performanceDiagnostics()
        XCTAssertEqual(materializedRecordCount, 1)
    }

    @MainActor
    func testRealmNativeRankingScalesToTenThousandRecords() async throws {
        let directory = try makeTemporaryRealmDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("memory.realm")
        let store = try RealmMemoryStore(url: url)
        let timestamp = Date()
        let records = (0 ..< 10_000).map { index in
            MemoryRecord(
                id: String(format: "scale-%05d", index),
                namespace: "assistant",
                scope: "project",
                category: "fact",
                summary: "native ranking scale fixture",
                importance: Double(index) / 10_000,
                createdAt: timestamp
            )
        }
        for start in stride(
            from: 0,
            to: records.count,
            by: MemoryStoreLimits.maximumBulkRecordCount
        ) {
            let end = min(start + MemoryStoreLimits.maximumBulkRecordCount, records.count)
            try await store.putMany(Array(records[start ..< end]))
        }

        let clock = ContinuousClock()
        let start = clock.now
        let result = try await store.query(MemoryQuery(
            namespace: "assistant",
            limit: 32,
            maxCharacters: 10_000
        ))
        let duration = start.duration(to: clock.now)

        XCTAssertEqual(result.matches.count, 32)
        XCTAssertEqual(result.matches.first?.record.id, "scale-09999")
        XCTAssertTrue(result.truncated)
        XCTAssertLessThan(
            duration,
            .seconds(1),
            "A native Realm sort and bounded prefix should stay comfortably below one second."
        )
        let materializedRecordCount = await store.performanceDiagnostics()
        XCTAssertEqual(materializedRecordCount, 32)

        let diagnostics = try await store.diagnostics(namespace: "assistant")
        XCTAssertEqual(diagnostics.totalRecords, 10_000)
        XCTAssertEqual(diagnostics.activeRecords, 10_000)
        XCTAssertEqual(diagnostics.countsByScope, ["project": 10_000])
        XCTAssertEqual(diagnostics.countsByCategory, ["fact": 10_000])

        let configuration = Realm.Configuration(
            fileURL: url,
            schemaVersion: RealmMemoryStoreMigration.schemaVersion,
            objectTypes: [
                RealmMemoryRecord.self,
                RealmMemoryTag.self,
                RealmMemoryRelatedID.self,
                RealmMemorySearchToken.self,
                RealmMemoryDedupeClaim.self,
                RealmMemoryDiagnosticsSnapshot.self,
            ]
        )
        try autoreleasepool {
            let realm = try Realm(configuration: configuration)
            XCTAssertEqual(realm.objects(RealmMemoryDiagnosticsSnapshot.self).count, 1)
            realm.invalidate()
        }
    }

    func testRealmMemoryRejectsOversizedCandidatesBeforeApplyingTheNativeLimit() async throws {
        let directory = try makeTemporaryRealmDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try RealmMemoryStore(url: directory.appendingPathComponent("memory.realm"))
        let oversized = (0 ..< 250).map { index in
            MemoryRecord(
                id: String(format: "oversized-%03d", index),
                namespace: "assistant",
                scope: "project",
                category: "fact",
                summary: String(repeating: "x", count: 2_000),
                importance: 1
            )
        }
        try await store.putMany(oversized + [
            MemoryRecord(
                id: "fits",
                namespace: "assistant",
                scope: "project",
                category: "fact",
                summary: "small result",
                importance: 0.1
            ),
        ])

        await store.resetPerformanceDiagnostics()
        let result = try await store.query(MemoryQuery(
            namespace: "assistant",
            limit: 1,
            maxCharacters: 100
        ))

        XCTAssertEqual(result.matches.map(\.record.id), ["fits"])
        XCTAssertFalse(result.truncated)
        let materializedRecordCount = await store.performanceDiagnostics()
        XCTAssertEqual(materializedRecordCount, 1)
    }

    func testRealmMemoryUsesPersistedTextPredicateBeforeNativeFieldRanking() async throws {
        let directory = try makeTemporaryRealmDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try RealmMemoryStore(url: directory.appendingPathComponent("memory.realm"))
        try await store.putMany([
            MemoryRecord(
                id: "high-importance-nonmatch",
                namespace: "assistant",
                scope: "project",
                category: "fact",
                summary: "Unrelated preference",
                importance: 1
            ),
            MemoryRecord(
                id: "text-match",
                namespace: "assistant",
                scope: "project",
                category: "fact",
                summary: "The launch codename is Firefly",
                importance: 0.1
            ),
        ])

        await store.resetPerformanceDiagnostics()
        let result = try await store.query(MemoryQuery(
            namespace: "assistant",
            text: "Firefly",
            limit: 1,
            maxCharacters: 1_000
        ))

        XCTAssertEqual(result.matches.map(\.record.id), ["text-match"])
        XCTAssertEqual(result.matches.first?.explanation.executionMethod, .databaseNative)
        let materializedRecordCount = await store.performanceDiagnostics()
        XCTAssertEqual(materializedRecordCount, 1)
    }

    @MainActor
    func testRealmMemoryUsesStructuredRecordSchema() async throws {
        let directory = try makeTemporaryRealmDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("memory.realm")
        let record = MemoryRecord(
            id: "structured-record",
            namespace: "assistant",
            scope: "project",
            category: "preference",
            summary: "Structured Realm record",
            evidence: ["Stored as a Realm list"],
            importance: 0.9,
            tags: ["realm"],
            relatedIDs: ["project-1"],
            dedupeKey: "structured-dedupe",
            attributes: .object(["source": .string("test")])
        )
        let store = try RealmMemoryStore(url: url)
        try await store.put(record)

        let configuration = Realm.Configuration(
            fileURL: url,
            schemaVersion: RealmMemoryStoreMigration.schemaVersion,
            objectTypes: [
                RealmMemoryRecord.self,
                RealmMemoryTag.self,
                RealmMemoryRelatedID.self,
                RealmMemorySearchToken.self,
                RealmMemoryDedupeClaim.self,
                RealmMemoryDiagnosticsSnapshot.self,
            ]
        )
        try autoreleasepool {
            let realm = try Realm(configuration: configuration)
            let object = try XCTUnwrap(realm.objects(RealmMemoryRecord.self).first)
            XCTAssertEqual(object.summary, record.summary)
            XCTAssertEqual(Array(object.evidence), record.evidence)
            XCTAssertEqual(object.tagEntities.map(\.value), record.tags)
            XCTAssertEqual(object.relatedIDEntities.map(\.value), record.relatedIDs)
            XCTAssertTrue(object.searchTokenEntities.map(\.value).contains("structured"))
            XCTAssertFalse(object.objectSchema.properties.contains { $0.name == "encodedRecord" })
            XCTAssertNil(object.objectSchema["tags"])
            XCTAssertNil(object.objectSchema["relatedIDs"])
            XCTAssertNil(object.objectSchema["searchTokens"])
            XCTAssertTrue(try XCTUnwrap(realm.schema["RealmMemoryTag"]?["value"]).isIndexed)
            XCTAssertTrue(try XCTUnwrap(realm.schema["RealmMemoryRelatedID"]?["value"]).isIndexed)
            XCTAssertTrue(try XCTUnwrap(realm.schema["RealmMemorySearchToken"]?["value"]).isIndexed)
            let claim = try XCTUnwrap(realm.objects(RealmMemoryDedupeClaim.self).first)
            XCTAssertEqual(claim.record?.key, object.key)
            XCTAssertNil(claim.objectSchema["recordKey"])
            XCTAssertNil(realm.schema["RealmMemoryAggregate"])
            let snapshot = try XCTUnwrap(realm.objects(RealmMemoryDiagnosticsSnapshot.self).first)
            XCTAssertEqual(snapshot.totalRecords, 1)
            XCTAssertEqual(snapshot.activeRecords, 1)
            XCTAssertEqual(snapshot.countsByScope["project"], 1)
            XCTAssertEqual(snapshot.countsByCategory["preference"], 1)
            realm.invalidate()
        }

        let loaded = try await store.record(id: record.id, namespace: record.namespace)
        XCTAssertEqual(loaded, record)
    }

    @MainActor
    func testRealmMemoryStructuredUpsertUpdatesFieldsAndIndexesAtomically() async throws {
        let directory = try makeTemporaryRealmDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("memory.realm")
        let original = MemoryRecord(
            id: "original",
            namespace: "assistant",
            scope: "project",
            category: "fact",
            summary: "Old firefly value",
            dedupeKey: "shared"
        )
        let replacement = MemoryRecord(
            id: "replacement",
            namespace: "assistant",
            scope: "project",
            category: "fact",
            summary: "New kestrel value",
            evidence: ["Updated evidence"],
            tags: ["updated"]
        )
        let store = try RealmMemoryStore(url: url)
        try await store.put(original)
        try await store.upsert(replacement, dedupeKey: "shared")

        let configuration = Realm.Configuration(
            fileURL: url,
            schemaVersion: RealmMemoryStoreMigration.schemaVersion,
            objectTypes: [
                RealmMemoryRecord.self,
                RealmMemoryTag.self,
                RealmMemoryRelatedID.self,
                RealmMemorySearchToken.self,
                RealmMemoryDedupeClaim.self,
                RealmMemoryDiagnosticsSnapshot.self,
            ]
        )
        try autoreleasepool {
            let realm = try Realm(configuration: configuration)
            let object = try XCTUnwrap(realm.objects(RealmMemoryRecord.self).first)
            XCTAssertEqual(object.recordID, replacement.id)
            let searchTokens = object.searchTokenEntities.map(\.value)
            XCTAssertFalse(searchTokens.contains("firefly"))
            XCTAssertTrue(searchTokens.contains("kestrel"))
            realm.invalidate()
        }

        var expected = replacement
        expected.dedupeKey = "shared"
        let deletedOriginal = try await store.record(id: original.id, namespace: original.namespace)
        let loadedReplacement = try await store.record(
            id: replacement.id,
            namespace: replacement.namespace
        )
        XCTAssertNil(deletedOriginal)
        XCTAssertEqual(loadedReplacement, expected)
    }

    func testPersistentMemoryAdaptersShareRankingProfileSemantics() async throws {
        let directory = try makeTemporaryRealmDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sqlite = try SQLiteMemoryStore(url: directory.appendingPathComponent("memory.sqlite"))
        let realm = try RealmMemoryStore(url: directory.appendingPathComponent("memory.realm"))
        let inMemory = InMemoryMemoryStore()
        let records = [
            MemoryRecord(
                id: "important-old",
                namespace: "assistant",
                scope: "project",
                category: "fact",
                summary: "shared query token",
                importance: 0.9,
                createdAt: Date(timeIntervalSince1970: 100),
                tags: ["shared"]
            ),
            MemoryRecord(
                id: "important-new",
                namespace: "assistant",
                scope: "project",
                category: "fact",
                summary: "shared query token",
                importance: 0.9,
                createdAt: Date(timeIntervalSince1970: 200),
                tags: ["shared"]
            ),
            MemoryRecord(
                id: "recent",
                namespace: "assistant",
                scope: "project",
                category: "fact",
                summary: "shared query token",
                importance: 0.5,
                createdAt: Date(timeIntervalSince1970: 300),
                tags: ["shared"]
            ),
        ]
        try await sqlite.putMany(records)
        try await realm.putMany(records)
        try await inMemory.putMany(records)

        for profile in [
            MemoryRankingProfile.importanceThenRecency,
            .recencyThenImportance,
        ] {
            let query = MemoryQuery(
                namespace: "assistant",
                text: "shared token",
                tags: ["shared"],
                ranking: profile,
                limit: 10,
                maxCharacters: 10_000
            )
            let expected = try await inMemory.query(query).matches.map(\.record.id)
            let sqliteIDs = try await sqlite.query(query).matches.map(\.record.id)
            let realmIDs = try await realm.query(query).matches.map(\.record.id)
            XCTAssertEqual(sqliteIDs, expected, "SQLite profile: \(profile)")
            XCTAssertEqual(realmIDs, expected, "Realm profile: \(profile)")
        }
    }

    func testMemoryAdaptersShareExactAndCanonicalUnicodeTokenSemantics() async throws {
        let directory = try makeTemporaryRealmDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stores: [(String, any MemoryStoring)] = [
            ("memory", InMemoryMemoryStore()),
            ("sqlite", try SQLiteMemoryStore(
                url: directory.appendingPathComponent("unicode-memory.sqlite")
            )),
            ("realm", try RealmMemoryStore(
                url: directory.appendingPathComponent("unicode-memory.realm")
            )),
        ]
        let record = MemoryRecord(
            id: "accented",
            namespace: "assistant",
            scope: "user",
            category: "preference",
            summary: "Favorite café in Sydney",
            importance: 0.8
        )
        for (_, store) in stores {
            try await store.put(record)
        }

        for (name, store) in stores {
            let unaccented = try await store.query(MemoryQuery(
                namespace: "assistant",
                text: "cafe"
            ))
            XCTAssertEqual(unaccented.matches, [], name)

            let decomposed = try await store.query(MemoryQuery(
                namespace: "assistant",
                text: "cafe\u{301}"
            ))
            XCTAssertEqual(decomposed.matches.map(\.record.id), [record.id], name)
        }
    }

    func testRealmDiagnosticsSnapshotTracksEveryMutationPath() async throws {
        let directory = try makeTemporaryRealmDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("memory.realm")
        let store = try RealmMemoryStore(url: url)
        try await store.putMany([
            MemoryRecord(
                id: "first",
                namespace: "assistant",
                scope: "project",
                category: "fact",
                summary: "first",
                dedupeKey: "replace-me"
            ),
            MemoryRecord(
                id: "second",
                namespace: "assistant",
                scope: "thread",
                category: "preference",
                summary: "second"
            ),
        ])
        try await store.archive(ids: ["second"], namespace: "assistant")
        try await store.upsert(
            MemoryRecord(
                id: "replacement",
                namespace: "assistant",
                scope: "user",
                category: "summary",
                summary: "replacement"
            ),
            dedupeKey: "replace-me"
        )

        var diagnostics = try await store.diagnostics(namespace: "assistant")
        XCTAssertEqual(diagnostics.totalRecords, 2)
        XCTAssertEqual(diagnostics.activeRecords, 1)
        XCTAssertEqual(diagnostics.archivedRecords, 1)
        XCTAssertEqual(diagnostics.countsByScope, ["thread": 1, "user": 1])
        XCTAssertEqual(diagnostics.countsByCategory, ["preference": 1, "summary": 1])

        try await store.delete(ids: ["second"], namespace: "assistant")
        diagnostics = try await store.diagnostics(namespace: "assistant")
        XCTAssertEqual(diagnostics.totalRecords, 1)
        XCTAssertEqual(diagnostics.activeRecords, 1)
        XCTAssertEqual(diagnostics.archivedRecords, 0)
        XCTAssertEqual(diagnostics.countsByScope, ["user": 1])
        XCTAssertEqual(diagnostics.countsByCategory, ["summary": 1])

        let now = Date()
        try await store.put(MemoryRecord(
            id: "expired",
            namespace: "assistant",
            scope: "thread",
            category: "transient",
            summary: "expired",
            expiresAt: now.addingTimeInterval(-1)
        ))
        try await store.compact(MemoryCompactionRequest(
            replacement: MemoryRecord(
                id: "compacted",
                namespace: "assistant",
                scope: "project",
                category: "condensed",
                summary: "compacted"
            ),
            sourceIDs: ["replacement", "replacement"]
        ))
        let prunedCount = try await store.pruneExpired(now: now, namespace: "assistant")
        XCTAssertEqual(prunedCount, 1)

        diagnostics = try await store.diagnostics(namespace: "assistant")
        XCTAssertEqual(diagnostics.totalRecords, 2)
        XCTAssertEqual(diagnostics.activeRecords, 1)
        XCTAssertEqual(diagnostics.archivedRecords, 1)
        XCTAssertEqual(diagnostics.countsByScope, ["user": 1, "project": 1])
        XCTAssertEqual(diagnostics.countsByCategory, ["summary": 1, "condensed": 1])

        try await store.delete(
            ids: ["replacement", "replacement", "compacted"],
            namespace: "assistant"
        )
        diagnostics = try await store.diagnostics(namespace: "assistant")
        XCTAssertEqual(diagnostics.totalRecords, 0)
        XCTAssertEqual(diagnostics.activeRecords, 0)
        XCTAssertEqual(diagnostics.archivedRecords, 0)
        XCTAssertEqual(diagnostics.countsByScope, [:])
        XCTAssertEqual(diagnostics.countsByCategory, [:])
        try autoreleasepool {
            let realm = try Realm(configuration: Realm.Configuration(
                fileURL: url,
                schemaVersion: RealmMemoryStoreMigration.schemaVersion,
                objectTypes: RealmMemorySchema.objectTypes
            ))
            XCTAssertTrue(realm.objects(RealmMemoryDiagnosticsSnapshot.self).isEmpty)
            realm.invalidate()
        }
    }

    func testMigratesSQLiteRuntimeStateIntoRealm() async throws {
        let directory = try makeTemporaryRealmDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sqlite = try SQLiteRuntimeStateStore(url: directory.appendingPathComponent("runtime.sqlite"))
        let realm = try RealmRuntimeStateStore(url: directory.appendingPathComponent("runtime.realm"))
        let thread = AgentThread(id: "migration-thread", title: "Migrated")
        let messages = (1 ... 3).map { sequence in
            AgentMessage(
                id: "migration-message-\(sequence)",
                threadID: thread.id,
                role: sequence.isMultiple(of: 2) ? .assistant : .user,
                text: "migration \(sequence)",
                images: sequence == 3 ? [.png(Data([1, 2, 3]))] : []
            )
        }
        let history = messages.enumerated().map { index, message in
            AgentHistoryRecord(
                sequenceNumber: index + 7,
                createdAt: message.createdAt,
                item: .message(message)
            )
        }
        let state = StoredRuntimeState(
            threads: [thread],
            historyByThread: [thread.id: history],
            contextStateByThread: [thread.id: AgentThreadContextState(
                threadID: thread.id,
                effectiveMessages: [messages[2]]
            )]
        )
        try await sqlite.saveState(state)

        let report = try await RuntimeStoreMigrator.migrate(
            from: sqlite,
            to: realm,
            batchSize: 1
        )
        XCTAssertEqual(report.threadCount, 1)
        XCTAssertEqual(report.historyRecordCount, 3)
        XCTAssertEqual(report.contextStateCount, 1)
        let migratedState = try await realm.loadState()
        XCTAssertEqual(migratedState, state)
    }

    func testRuntimeMigrationKeysetDoesNotSkipThreadsWithTiedDates() async throws {
        let directory = try makeTemporaryRealmDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sqlite = try SQLiteRuntimeStateStore(url: directory.appendingPathComponent("runtime.sqlite"))
        let realm = try RealmRuntimeStateStore(url: directory.appendingPathComponent("runtime.realm"))
        let timestamp = Date(timeIntervalSince1970: 100)
        let threads = (0 ..< 5).map { index in
            AgentThread(
                id: "tied-thread-\(index)",
                title: "Thread \(index)",
                createdAt: timestamp,
                updatedAt: timestamp
            )
        }
        try await sqlite.saveState(StoredRuntimeState(threads: threads))

        let report = try await RuntimeStoreMigrator.migrate(
            from: sqlite,
            to: realm,
            batchSize: 2
        )

        XCTAssertEqual(report.threadCount, threads.count)
        let migratedThreads = try await realm.loadState().threads
        XCTAssertEqual(Set(migratedThreads), Set(threads))
    }

    func testRuntimeMigrationRejectsSameStoreWithoutDeletingIt() async throws {
        let directory = try makeTemporaryRealmDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("runtime.sqlite")
        let source = try SQLiteRuntimeStateStore(url: url)
        let destination = try SQLiteRuntimeStateStore(url: url)
        let thread = AgentThread(id: "preserved-same-store")
        try await source.saveState(StoredRuntimeState(threads: [thread]))

        do {
            _ = try await RuntimeStoreMigrator.migrate(
                from: source,
                to: destination,
                overwriteDestination: true
            )
            XCTFail("Expected the identical store migration to be rejected.")
        } catch let error as CodexKitStoreMigrationError {
            XCTAssertEqual(error, .sameSourceAndDestination)
        }

        let preservedThreads = try await source.loadState().threads
        XCTAssertEqual(preservedThreads, [thread])
    }

    func testRuntimeMigrationRejectsUnsafeOverwriteAndPreservesDestination() async throws {
        let source = InMemoryRuntimeStateStore()
        let destination = InMemoryRuntimeStateStore()
        let sourceThread = AgentThread(id: "source")
        let destinationThread = AgentThread(id: "destination")
        try await source.saveState(StoredRuntimeState(threads: [sourceThread]))
        try await destination.saveState(StoredRuntimeState(threads: [destinationThread]))

        do {
            _ = try await RuntimeStoreMigrator.migrate(
                from: source,
                to: destination,
                overwriteDestination: true
            )
            XCTFail("Expected an unsafe overwrite to be rejected.")
        } catch let error as CodexKitStoreMigrationError {
            XCTAssertEqual(error, .overwriteDestinationUnsupported)
        }

        let preservedThreads = try await destination.loadState().threads
        XCTAssertEqual(preservedThreads, [destinationThread])
    }

    func testMigratesSQLiteMemoryRecordsIntoRealm() async throws {
        let directory = try makeTemporaryRealmDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sqlite = try SQLiteMemoryStore(url: directory.appendingPathComponent("memory.sqlite"))
        let realm = try RealmMemoryStore(url: directory.appendingPathComponent("memory.realm"))
        let records = [
            MemoryRecord(
                id: "active",
                namespace: "assistant",
                scope: "feature:migration",
                category: "preference",
                summary: "Keep this active",
                createdAt: Date(timeIntervalSince1970: 1)
            ),
            MemoryRecord(
                id: "archived",
                namespace: "assistant",
                scope: "feature:migration",
                category: "fact",
                summary: "Keep this archived",
                createdAt: Date(timeIntervalSince1970: 2),
                status: .archived
            ),
        ]
        try await sqlite.putMany(records)

        let report = try await MemoryStoreMigrator.migrate(
            namespaces: ["assistant"],
            from: sqlite,
            to: realm,
            batchSize: 1
        )

        XCTAssertEqual(report, MemoryStoreMigrationReport(namespaceCount: 1, recordCount: 2))
        let migrated = try await realm.list(namespace: "assistant", includeArchived: true)
        XCTAssertEqual(migrated, Array(records.reversed()))
    }

    func testMemoryMigrationKeysetDoesNotSkipRecordsWithTiedDates() async throws {
        let directory = try makeTemporaryRealmDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sqlite = try SQLiteMemoryStore(url: directory.appendingPathComponent("memory.sqlite"))
        let realm = try RealmMemoryStore(url: directory.appendingPathComponent("memory.realm"))
        let timestamp = Date(timeIntervalSince1970: 100)
        let records = (0 ..< 5).map { index in
            MemoryRecord(
                id: "tied-memory-\(index)",
                namespace: "assistant",
                scope: "project",
                category: "fact",
                summary: "Memory \(index)",
                createdAt: timestamp
            )
        }
        try await sqlite.putMany(records)

        let report = try await MemoryStoreMigrator.migrate(
            namespaces: ["assistant"],
            from: sqlite,
            to: realm,
            batchSize: 2
        )

        XCTAssertEqual(report.recordCount, records.count)
        let migratedRecords = try await realm.list(namespace: "assistant", includeArchived: true)
        XCTAssertEqual(Set(migratedRecords), Set(records))
    }

    func testMemoryMigrationRejectsSameStoreWithoutDeletingIt() async throws {
        let store = InMemoryMemoryStore()
        let record = MemoryRecord(
            id: "preserved-same-store",
            namespace: "assistant",
            scope: "project",
            category: "fact",
            summary: "Preserve me"
        )
        try await store.put(record)

        do {
            _ = try await MemoryStoreMigrator.migrate(
                namespaces: ["assistant"],
                from: store,
                to: store
            )
            XCTFail("Expected the identical store migration to be rejected.")
        } catch let error as CodexKitStoreMigrationError {
            XCTAssertEqual(error, .sameSourceAndDestination)
        }

        let preservedRecords = try await store.list(namespace: "assistant")
        XCTAssertEqual(preservedRecords, [record])
    }

    func testPersistentMemoryWritesWaitForTheMigrationLease() async throws {
        let directory = try makeTemporaryRealmDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sqlite = try SQLiteMemoryStore(url: directory.appendingPathComponent("memory.sqlite"))
        let realm = try RealmMemoryStore(url: directory.appendingPathComponent("memory.realm"))

        try await assertWriteWaitsForMigrationLease(
            store: sqlite,
            recordID: "sqlite-blocked"
        )
        try await assertWriteWaitsForMigrationLease(
            store: realm,
            recordID: "realm-blocked"
        )
    }

    func testPersistentMemoryRankingCursorsCoverTiedRowsExactlyOnce() async throws {
        let directory = try makeTemporaryRealmDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stores: [any MemoryStoring] = [
            try SQLiteMemoryStore(url: directory.appendingPathComponent("cursor.sqlite")),
            try RealmMemoryStore(url: directory.appendingPathComponent("cursor.realm")),
        ]

        for store in stores {
            try await assertRankingCursorCoversTiedRows(store)
        }
    }

    func testRuntimePackingPreservesTheRankedPrefixInPersistentStores() async throws {
        let directory = try makeTemporaryRealmDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stores: [any MemoryStoring] = [
            try SQLiteMemoryStore(url: directory.appendingPathComponent("packing.sqlite")),
            try RealmMemoryStore(url: directory.appendingPathComponent("packing.realm")),
        ]
        let runtime = try AgentRuntime(configuration: .init(
            authProvider: DemoChatGPTAuthProvider(),
            secureStore: KeychainSessionSecureStore(
                service: "CodexKitTests.Packing",
                account: UUID().uuidString
            ),
            backend: InMemoryAgentBackend(),
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: InMemoryRuntimeStateStore()
        ))

        for store in stores {
            try await assertRuntimePackingPreservesRankedPrefix(runtime: runtime, store: store)
        }
    }

    private func makeTemporaryRealmDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexKitRealmTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func assertWriteWaitsForMigrationLease(
        store: any MemoryStoring & StoreMigrationCoordinating,
        recordID: String
    ) async throws {
        let record = MemoryRecord(
            id: recordID,
            namespace: "lease-test",
            scope: "project",
            category: "fact",
            summary: "This write must wait"
        )
        let gate = MigrationLeaseGate()
        let lease = Task {
            try await RuntimeStoreMutationCoordinator.shared.performExclusively(
                for: [store.migrationCoordinationRootURL]
            ) {
                await gate.enterAndWaitForRelease()
            }
        }
        await gate.waitUntilEntered()
        let pendingWrite = Task { try await store.put(record) }
        try await Task.sleep(for: .milliseconds(50))
        let duringLease = try await store.list(namespace: record.namespace)
        XCTAssertTrue(duringLease.isEmpty)

        await gate.release()
        try await lease.value
        try await pendingWrite.value
        let afterLease = try await store.list(namespace: record.namespace)
        XCTAssertEqual(afterLease.map(\.id), [record.id])
    }

    private func assertRankingCursorCoversTiedRows(
        _ store: any MemoryStoring
    ) async throws {
        let timestamp = Date(timeIntervalSince1970: 100)
        let records = (0 ..< 7).map { index in
            MemoryRecord(
                id: "tied-cursor-\(index)",
                namespace: "cursor-test",
                scope: "project",
                category: "fact",
                summary: "tied cursor row",
                importance: 0.5,
                createdAt: timestamp
            )
        }
        try await store.putMany(records)

        var cursor: MemoryQueryCursor?
        var recordIDs: [String] = []
        repeat {
            let page = try await store.query(MemoryQuery(
                namespace: "cursor-test",
                limit: 2,
                maxCharacters: 1_000,
                cursor: cursor
            ))
            recordIDs.append(contentsOf: page.matches.map(\.record.id))
            cursor = page.nextCursor
        } while cursor != nil

        XCTAssertEqual(recordIDs.count, records.count)
        XCTAssertEqual(Set(recordIDs), Set(records.map(\.id)))
    }

    private func assertRuntimePackingPreservesRankedPrefix(
        runtime: AgentRuntime,
        store: any MemoryStoring
    ) async throws {
        let first = MemoryRecord(
            id: "packing-first",
            namespace: "packing-test",
            scope: "project",
            category: "fact",
            summary: "shared memory first",
            importance: 1
        )
        let medium = MemoryRecord(
            id: "packing-medium",
            namespace: "packing-test",
            scope: "project",
            category: "fact",
            summary: "shared memory medium medium medium medium",
            importance: 0.8
        )
        let small = MemoryRecord(
            id: "packing-small",
            namespace: "packing-test",
            scope: "project",
            category: "fact",
            summary: "shared memory tiny",
            importance: 0.1
        )
        try await store.putMany([first, medium, small])
        let firstCost = MemoryQueryEngine.renderedCharacterCount(for: first)
        let mediumCost = MemoryQueryEngine.renderedCharacterCount(for: medium)
        let smallCost = MemoryQueryEngine.renderedCharacterCount(for: small)
        let contentBudget = firstCost + 1 + smallCost
        XCTAssertGreaterThan(mediumCost, smallCost)
        XCTAssertLessThanOrEqual(mediumCost, contentBudget)

        let result = try await runtime.packedMemoryQuery(
            MemoryQuery(
                namespace: "packing-test",
                text: "shared memory",
                textMatchPolicy: .allTokens,
                limit: 2,
                maxCharacters: contentBudget
            ),
            store: store
        )

        XCTAssertEqual(result.matches.map(\.record.id), [first.id])
        XCTAssertTrue(result.truncated)
    }

    private func attachmentState(threadID: String, byte: UInt8) -> StoredRuntimeState {
        let thread = AgentThread(id: threadID)
        let message = AgentMessage(
            id: "message",
            threadID: threadID,
            role: .user,
            text: threadID,
            images: [.png(Data([byte]), id: "image")]
        )
        return StoredRuntimeState(
            threads: [thread],
            historyByThread: [threadID: [AgentHistoryRecord(
                id: "record",
                sequenceNumber: 1,
                createdAt: message.createdAt,
                item: .message(message)
            )]]
        )
    }

    private func assertConcurrentAttachmentMutationSafety(
        first: any RuntimeStateStoring,
        second: any RuntimeStateStoring
    ) async throws {
        let threads = [AgentThread(id: "first"), AgentThread(id: "second")]
        try await first.saveState(StoredRuntimeState(threads: threads))

        let firstRecord = attachmentRecord(threadID: threads[0].id, sequence: 1, byte: 1)
        async let preparation = second.prepare()
        async let firstAppend: Void = first.apply([
            .appendHistoryItems(threadID: threads[0].id, items: [firstRecord]),
        ])
        _ = try await preparation
        try await firstAppend

        let secondRecord = attachmentRecord(threadID: threads[1].id, sequence: 1, byte: 2)
        let nextFirstRecord = attachmentRecord(threadID: threads[0].id, sequence: 2, byte: 3)
        async let secondAppend: Void = second.apply([
            .appendHistoryItems(threadID: threads[1].id, items: [secondRecord]),
        ])
        async let nextFirstAppend: Void = first.apply([
            .appendHistoryItems(threadID: threads[0].id, items: [nextFirstRecord]),
        ])
        _ = try await (secondAppend, nextFirstAppend)

        let loaded = try await second.loadState()
        let storedBytes = try loaded.historyByThread.values
            .flatMap { $0 }
            .map { record -> UInt8 in
                guard case let .message(message) = record.item,
                      let byte = message.images.first?.data.first
                else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                return byte
            }
        XCTAssertEqual(Set(storedBytes), Set([1, 2, 3]))
    }

    private func attachmentRecord(
        threadID: String,
        sequence: Int,
        byte: UInt8
    ) -> AgentHistoryRecord {
        let message = AgentMessage(
            id: "message-\(sequence)",
            threadID: threadID,
            role: .user,
            text: "attachment \(sequence)",
            images: [.png(Data([byte]), id: "image-\(sequence)")]
        )
        return AgentHistoryRecord(
            id: "record-\(sequence)",
            sequenceNumber: sequence,
            createdAt: message.createdAt,
            item: .message(message)
        )
    }

    private func assertHistoryQueryParity<Store>(store: Store) async throws
    where Store: AgentRuntimeQueryableStore {
        let thread = AgentThread(id: "query-parity")
        let timestamps: [TimeInterval] = [10, 10, 5, 20]
        let records = timestamps.enumerated().map { offset, timestamp in
            let sequence = offset + 1
            let message = AgentMessage(
                id: "message-\(sequence)",
                threadID: thread.id,
                role: .user,
                text: "\(sequence)",
                createdAt: Date(timeIntervalSince1970: timestamp)
            )
            return AgentHistoryRecord(
                id: "record-\(sequence)",
                sequenceNumber: sequence,
                createdAt: message.createdAt,
                item: .message(message)
            )
        }
        try await store.saveState(StoredRuntimeState(
            threads: [thread],
            historyByThread: [thread.id: records]
        ))

        let descending = try await store.execute(HistoryItemsQuery(
            threadID: thread.id,
            sort: .createdAt(.descending),
            page: AgentQueryPage(limit: 2)
        ))
        XCTAssertEqual(descending.records.map(\.sequenceNumber), [4, 2])
        XCTAssertTrue(descending.hasMoreBefore)
        let older = try await store.execute(HistoryItemsQuery(
            threadID: thread.id,
            sort: .createdAt(.descending),
            page: AgentQueryPage(limit: 2, cursor: descending.nextCursor)
        ))
        XCTAssertEqual(older.records.map(\.sequenceNumber), [1, 3])

        do {
            _ = try await store.execute(HistoryItemsQuery(
                threadID: thread.id,
                sort: .createdAt(.ascending),
                page: AgentQueryPage(limit: 2, cursor: descending.nextCursor)
            ))
            XCTFail("Expected a cursor bound to descending order to be rejected.")
        } catch let error as AgentRuntimeError {
            XCTAssertEqual(error.code, "invalid_history_cursor")
        }
    }

    func testPersistentMemoryAdaptersEnforceMinimumTokenMatchesAndExplainCoverage() async throws {
        let directory = try makeTemporaryRealmDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sqlite = try SQLiteMemoryStore(
            url: directory.appendingPathComponent("memory.sqlite")
        )
        let realm = try RealmMemoryStore(
            url: directory.appendingPathComponent("memory.realm")
        )
        let records = [
            MemoryRecord(
                id: "strong-text",
                namespace: "assistant",
                scope: "project",
                category: "fact",
                summary: "brisk evening walk steps",
                importance: 0.1
            ),
            MemoryRecord(
                id: "weak-text",
                namespace: "assistant",
                scope: "project",
                category: "fact",
                summary: "evening status update",
                importance: 1
            ),
        ]
        try await sqlite.putMany(records)
        try await realm.putMany(records)

        for store in [sqlite as any MemoryStoring, realm as any MemoryStoring] {
            let selective = try await store.query(MemoryQuery(
                namespace: "assistant",
                text: "brisk evening walk steps",
                textMatchPolicy: .atLeastTokens(2),
                limit: 2,
                maxCharacters: 1_000
            ))
            XCTAssertEqual(selective.matches.map(\.record.id), ["strong-text"])
            XCTAssertEqual(selective.matches[0].explanation.matchedTokenCount, 4)
            XCTAssertEqual(selective.matches[0].explanation.queryTokenCount, 4)
            XCTAssertEqual(selective.matches[0].explanation.textCoverage, 1)
            XCTAssertEqual(selective.matches[0].explanation.rankingProfile, .importanceThenRecency)
            XCTAssertEqual(selective.matches[0].explanation.executionMethod, .databaseNative)

            let permissive = try await store.query(MemoryQuery(
                namespace: "assistant",
                text: "brisk evening walk steps",
                textMatchPolicy: .anyToken,
                limit: 1,
                maxCharacters: 1_000
            ))
            XCTAssertEqual(permissive.matches.map(\.record.id), ["weak-text"])
            XCTAssertEqual(permissive.matches[0].explanation.matchedTokenCount, 1)
            XCTAssertEqual(permissive.matches[0].explanation.queryTokenCount, 4)

            let zeroCharacterBudget = try await store.query(MemoryQuery(
                namespace: "assistant",
                text: "evening",
                limit: 1,
                maxCharacters: 0
            ))
            XCTAssertTrue(zeroCharacterBudget.matches.isEmpty)
            XCTAssertFalse(zeroCharacterBudget.truncated)
        }
    }

    func testRealmCanonicalizesNegativeZeroImportanceForFilteringAndOrdering() async throws {
        let directory = try makeTemporaryRealmDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try RealmMemoryStore(
            url: directory.appendingPathComponent("negative-zero.realm")
        )
        try await store.putMany([
            MemoryRecord(
                id: "newer-negative-zero",
                namespace: "assistant",
                scope: "project",
                category: "fact",
                summary: "newer",
                importance: -0.0,
                createdAt: Date(timeIntervalSince1970: 200)
            ),
            MemoryRecord(
                id: "older-positive-zero",
                namespace: "assistant",
                scope: "project",
                category: "fact",
                summary: "older",
                importance: 0.0,
                createdAt: Date(timeIntervalSince1970: 100)
            ),
        ])

        let result = try await store.query(MemoryQuery(
            namespace: "assistant",
            minImportance: 0,
            limit: 2,
            maxCharacters: 1_000
        ))
        XCTAssertEqual(result.matches.map(\.record.id), [
            "newer-negative-zero",
            "older-positive-zero",
        ])
    }

    private static func memoryPutError(
        store: RealmMemoryStore,
        record: MemoryRecord
    ) async -> MemoryStoreError? {
        do {
            try await store.put(record)
            return nil
        } catch let error as MemoryStoreError {
            return error
        } catch {
            XCTFail("Unexpected Realm memory error: \(error)")
            return nil
        }
    }

}

private actor MigrationLeaseGate {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func enterAndWaitForRelease() async {
        entered = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters.removeAll()
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
