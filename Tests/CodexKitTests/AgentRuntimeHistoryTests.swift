import CodexKit
import CodexKitUI
import XCTest

extension AgentRuntimeTests {
    func testFetchThreadSummaryAndLatestStructuredOutputWorkWithoutRestore() async throws {
        let backend = InMemoryAgentBackend(
            structuredResponseText: #"{"reply":"Your order is already in transit.","priority":"high"}"#
        )
        let stateStore = InMemoryRuntimeStateStore()
        let runtime = try makeHistoryRuntime(
            backend: backend,
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: stateStore
        )

        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread(title: "History Summary")
        _ = try await runtime.sendMessage(
            UserMessageRequest(text: "Draft a shipping reply."),
            in: thread.id,
            expecting: ShippingReplyDraft.self
        )

        let restoredRuntime = try makeHistoryRuntime(
            backend: backend,
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: stateStore
        )

        let summary = try await restoredRuntime.fetchThreadSummary(id: thread.id)
        XCTAssertEqual(summary.threadID, thread.id)
        XCTAssertEqual(summary.latestTurnStatus, .completed)
        XCTAssertEqual(summary.latestStructuredOutputMetadata?.formatName, "shipping_reply_draft")

        let metadata = try await restoredRuntime.fetchLatestStructuredOutputMetadata(id: thread.id)
        XCTAssertEqual(metadata, summary.latestStructuredOutputMetadata)

        let typed = try await restoredRuntime.fetchLatestStructuredOutput(
            id: thread.id,
            as: ShippingReplyDraft.self
        )
        XCTAssertEqual(
            typed,
            ShippingReplyDraft(
                reply: "Your order is already in transit.",
                priority: "high"
            )
        )
    }

    func testFetchThreadHistoryPagesMessagesBackwardChronologically() async throws {
        let runtime = try makeHistoryRuntime(
            backend: InMemoryAgentBackend(),
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: InMemoryRuntimeStateStore()
        )

        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread(title: "Paged Messages")
        _ = try await runtime.sendMessage(UserMessageRequest(text: "one"), in: thread.id)
        _ = try await runtime.sendMessage(UserMessageRequest(text: "two"), in: thread.id)
        _ = try await runtime.sendMessage(UserMessageRequest(text: "three"), in: thread.id)

        let filter = AgentHistoryFilter(
            includeMessages: true,
            includeToolCalls: false,
            includeToolResults: false,
            includeStructuredOutputs: false,
            includeApprovals: false,
            includeSystemEvents: false
        )

        let newestPage = try await runtime.fetchThreadHistory(
            id: thread.id,
            query: .init(limit: 2, direction: .backward, filter: filter)
        )
        XCTAssertEqual(messageTexts(in: newestPage), ["three", "Echo: three"])
        XCTAssertTrue(newestPage.hasMoreBefore)
        XCTAssertFalse(newestPage.hasMoreAfter)
        XCTAssertNotNil(newestPage.nextCursor)

        let olderPage = try await runtime.fetchThreadHistory(
            id: thread.id,
            query: .init(
                limit: 2,
                cursor: newestPage.nextCursor,
                direction: .backward,
                filter: filter
            )
        )
        XCTAssertEqual(messageTexts(in: olderPage), ["two", "Echo: two"])
        XCTAssertTrue(olderPage.hasMoreBefore)
        XCTAssertTrue(olderPage.hasMoreAfter)
    }

    @MainActor
    func testSummaryReflectsPendingApprovalWithoutRestore() async throws {
        let approvalInbox = ApprovalInbox()
        let stateStore = InMemoryRuntimeStateStore()
        let runtime = try makeHistoryRuntime(
            backend: InMemoryAgentBackend(),
            approvalPresenter: approvalInbox,
            stateStore: stateStore,
            tools: [
                .init(
                    definition: ToolDefinition(
                        name: "demo_lookup_profile",
                        description: "Lookup profile",
                        inputSchema: .object([:]),
                        approvalPolicy: .requiresApproval
                    ),
                    executor: AnyToolExecutor { invocation, _ in
                        .success(invocation: invocation, text: "approved-result")
                    }
                ),
            ]
        )

        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread(title: "Pending Approval")
        let stream = try await runtime.streamMessage(
            UserMessageRequest(text: "please use the tool"),
            in: thread.id
        )

        let drainTask = Task {
            for try await _ in stream {}
        }

        try await waitUntil {
            await MainActor.run {
                approvalInbox.currentRequest != nil
            }
        }

        let restoredRuntime = try makeHistoryRuntime(
            backend: InMemoryAgentBackend(),
            approvalPresenter: approvalInbox,
            stateStore: stateStore
        )
        let pendingSummary = try await restoredRuntime.fetchThreadSummary(id: thread.id)

        switch pendingSummary.pendingState {
        case let .approval(state):
            XCTAssertEqual(state.request.toolInvocation.toolName, "demo_lookup_profile")
        default:
            XCTFail("Expected approval pending state.")
        }

        approvalInbox.approveCurrent()
        _ = try await drainTask.value

        let completedSummary = try await restoredRuntime.fetchThreadSummary(id: thread.id)
        XCTAssertNil(completedSummary.pendingState)
    }

    func testSummaryReflectsPendingToolWaitWithoutRestore() async throws {
        let gate = ToolExecutionGate()
        let stateStore = InMemoryRuntimeStateStore()
        let runtime = try makeHistoryRuntime(
            backend: InMemoryAgentBackend(),
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: stateStore,
            tools: [
                .init(
                    definition: ToolDefinition(
                        name: "demo_lookup_profile",
                        description: "Lookup profile",
                        inputSchema: .object([:])
                    ),
                    executor: AnyToolExecutor { invocation, _ in
                        await gate.wait()
                        return .success(invocation: invocation, text: "tool-finished")
                    }
                ),
            ]
        )

        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread(title: "Pending Tool")
        let stream = try await runtime.streamMessage(
            UserMessageRequest(text: "please use the tool"),
            in: thread.id
        )

        let drainTask = Task {
            for try await _ in stream {}
        }

        let restoredRuntime = try makeHistoryRuntime(
            backend: InMemoryAgentBackend(),
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: stateStore
        )

        try await waitUntil {
            let summary = try await restoredRuntime.fetchThreadSummary(id: thread.id)
            if case .toolWait = summary.pendingState {
                return true
            }
            return false
        }

        let waitingSummary = try await restoredRuntime.fetchThreadSummary(id: thread.id)
        switch waitingSummary.pendingState {
        case let .toolWait(state):
            XCTAssertEqual(state.toolName, "demo_lookup_profile")
        default:
            XCTFail("Expected tool wait pending state.")
        }

        await gate.release()
        _ = try await drainTask.value

        let completedSummary = try await restoredRuntime.fetchThreadSummary(id: thread.id)
        XCTAssertNil(completedSummary.pendingState)
        XCTAssertEqual(completedSummary.latestToolState?.status, .completed)
    }

    func testPartialStructuredSnapshotPersistsUntilCommit() async throws {
        let backend = BlockingStructuredPartialBackend()
        let stateStore = InMemoryRuntimeStateStore()
        let runtime = try makeHistoryRuntime(
            backend: backend,
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: stateStore
        )

        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread(title: "Partial Structured")
        let stream = try await runtime.streamMessage(
            UserMessageRequest(text: "Draft a shipping reply."),
            in: thread.id,
            expecting: ShippingReplyDraft.self
        )

        let drainTask = Task {
            for try await _ in stream {}
        }

        await backend.waitForPartialEmission()

        let restoredRuntime = try makeHistoryRuntime(
            backend: backend,
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: stateStore
        )

        try await waitUntil {
            let summary = try await restoredRuntime.fetchThreadSummary(id: thread.id)
            return summary.latestPartialStructuredOutput != nil
        }

        let partialSummary = try await restoredRuntime.fetchThreadSummary(id: thread.id)
        XCTAssertEqual(partialSummary.latestPartialStructuredOutput?.formatName, "shipping_reply_draft")
        XCTAssertNil(partialSummary.latestStructuredOutputMetadata)

        await backend.releaseCommit()
        _ = try await drainTask.value

        let committedSummary = try await restoredRuntime.fetchThreadSummary(id: thread.id)
        XCTAssertNil(committedSummary.latestPartialStructuredOutput)
        XCTAssertEqual(committedSummary.latestStructuredOutputMetadata?.formatName, "shipping_reply_draft")
    }

    func testFileRuntimeStateStoreMigratesLegacyBlobForSummaryAndHistory() async throws {
        let thread = AgentThread(
            id: "legacy-thread",
            title: "Legacy Thread",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let message = AgentMessage(
            id: "legacy-message",
            threadID: thread.id,
            role: .assistant,
            text: "Hello from legacy state",
            createdAt: Date(timeIntervalSince1970: 101)
        )
        let legacyState = StoredRuntimeState(
            threads: [thread],
            messagesByThread: [thread.id: [message]]
        )

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        try JSONEncoder().encode(legacyState).write(to: url, options: .atomic)

        let store = FileRuntimeStateStore(url: url)
        let summary = try await store.fetchThreadSummary(id: thread.id)
        XCTAssertEqual(summary.latestAssistantMessagePreview, "Hello from legacy state")

        let history = try await store.fetchThreadHistory(
            id: thread.id,
            query: .init(
                limit: 10,
                direction: .backward,
                filter: AgentHistoryFilter(
                    includeMessages: true,
                    includeToolCalls: false,
                    includeToolResults: false,
                    includeStructuredOutputs: false,
                    includeApprovals: false,
                    includeSystemEvents: false
                )
            )
        )
        XCTAssertEqual(messageTexts(in: history), ["Hello from legacy state"])
    }

    func testPrepareStoreReturnsMetadataAndQueryableExecutionWorks() async throws {
        let stateStore = InMemoryRuntimeStateStore()
        let runtime = try makeHistoryRuntime(
            backend: InMemoryAgentBackend(),
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: stateStore
        )

        let metadata = try await runtime.prepareStore()
        XCTAssertEqual(metadata.logicalSchemaVersion, .v1)
        XCTAssertEqual(metadata.storeKind, "InMemoryRuntimeStateStore")
        XCTAssertTrue(metadata.capabilities.supportsPushdownQueries)

        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread(title: "Queryable")
        _ = try await runtime.sendMessage(UserMessageRequest(text: "hello"), in: thread.id)

        let threads = try await runtime.execute(
            ThreadMetadataQuery(
                threadIDs: [thread.id],
                limit: 1
            )
        )
        XCTAssertEqual(threads.first?.id, thread.id)

        let snapshots = try await runtime.execute(
            ThreadSnapshotQuery(
                threadIDs: [thread.id],
                limit: 1
            )
        )
        XCTAssertEqual(snapshots.first?.threadID, thread.id)

        let history = try await runtime.execute(
            HistoryItemsQuery(
                threadID: thread.id,
                kinds: [.message]
            )
        )
        XCTAssertEqual(history.records.count, 2)
    }

    func testRedactHistoryItemsPreservesRecordIdentityAndHidesPayload() async throws {
        let runtime = try makeHistoryRuntime(
            backend: InMemoryAgentBackend(),
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: InMemoryRuntimeStateStore()
        )

        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread(title: "Redactions")
        _ = try await runtime.sendMessage(UserMessageRequest(text: "top secret"), in: thread.id)

        let history = try await runtime.execute(
            HistoryItemsQuery(
                threadID: thread.id,
                kinds: [.message]
            )
        )
        guard let userRecord = history.records.first(where: {
            if case let .message(message) = $0.item {
                return message.role == .user
            }
            return false
        }) else {
            return XCTFail("Expected a persisted user message.")
        }

        try await runtime.redactHistoryItems(
            [userRecord.id],
            in: thread.id,
            reason: .init(code: "privacy", message: "User requested redaction")
        )

        let redactedHistory = try await runtime.execute(
            HistoryItemsQuery(
                threadID: thread.id,
                kinds: [.message]
            )
        )
        guard let redactedRecord = redactedHistory.records.first(where: { $0.id == userRecord.id }) else {
            return XCTFail("Expected redacted record to remain in history.")
        }

        XCTAssertNotNil(redactedRecord.redaction)
        if case let .message(message) = redactedRecord.item {
            XCTAssertEqual(message.text, "[Redacted]")
            XCTAssertTrue(message.images.isEmpty)
        } else {
            XCTFail("Expected redacted message item.")
        }
    }

    func testDeleteThreadRemovesThreadFromQueries() async throws {
        let runtime = try makeHistoryRuntime(
            backend: InMemoryAgentBackend(),
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: InMemoryRuntimeStateStore()
        )

        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread(title: "Delete Me")
        _ = try await runtime.sendMessage(UserMessageRequest(text: "bye"), in: thread.id)

        try await runtime.deleteThread(id: thread.id)

        let threads = try await runtime.execute(
            ThreadMetadataQuery(threadIDs: [thread.id])
        )
        XCTAssertTrue(threads.isEmpty)

        let snapshots = try await runtime.execute(
            ThreadSnapshotQuery(threadIDs: [thread.id])
        )
        XCTAssertTrue(snapshots.isEmpty)

        let history = try await runtime.execute(
            HistoryItemsQuery(threadID: thread.id)
        )
        XCTAssertTrue(history.records.isEmpty)
    }

    func testGRDBRuntimeStateStorePersistsSummariesAndQueriesAcrossReload() async throws {
        let url = temporaryRuntimeSQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let backend = InMemoryAgentBackend(
            structuredResponseText: #"{"reply":"The replacement is shipping today.","priority":"urgent"}"#
        )
        let store = try GRDBRuntimeStateStore(url: url)
        let runtime = try makeHistoryRuntime(
            backend: backend,
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: store
        )

        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread(title: "GRDB Thread")
        _ = try await runtime.sendMessage(
            UserMessageRequest(text: "Draft the shipping update."),
            in: thread.id,
            expecting: ShippingReplyDraft.self
        )

        let reloadedStore = try GRDBRuntimeStateStore(url: url)
        let reloadedRuntime = try makeHistoryRuntime(
            backend: backend,
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: reloadedStore
        )

        let metadata = try await reloadedRuntime.prepareStore()
        XCTAssertEqual(metadata.storeKind, "GRDBRuntimeStateStore")
        XCTAssertEqual(metadata.storeSchemaVersion, 2)

        let summary = try await reloadedRuntime.fetchThreadSummary(id: thread.id)
        XCTAssertEqual(summary.latestTurnStatus, .completed)
        XCTAssertEqual(summary.latestStructuredOutputMetadata?.formatName, "shipping_reply_draft")

        let snapshots = try await reloadedRuntime.execute(
            ThreadSnapshotQuery(threadIDs: [thread.id])
        )
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.threadID, thread.id)

        let history = try await reloadedRuntime.execute(
            HistoryItemsQuery(
                threadID: thread.id,
                kinds: [.message, .structuredOutput]
            )
        )
        XCTAssertFalse(history.records.isEmpty)

        let typed = try await reloadedRuntime.fetchLatestStructuredOutput(
            id: thread.id,
            as: ShippingReplyDraft.self
        )
        XCTAssertEqual(
            typed,
            ShippingReplyDraft(
                reply: "The replacement is shipping today.",
                priority: "urgent"
            )
        )
    }

    func testGRDBRuntimeStateStorePersistsRedactionAndDeletion() async throws {
        let url = temporaryRuntimeSQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let runtime = try makeHistoryRuntime(
            backend: InMemoryAgentBackend(),
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: try GRDBRuntimeStateStore(url: url)
        )

        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread(title: "GRDB Mutations")
        _ = try await runtime.sendMessage(UserMessageRequest(text: "please redact me"), in: thread.id)

        let messageHistory = try await runtime.execute(
            HistoryItemsQuery(threadID: thread.id, kinds: [.message])
        )
        guard let firstMessage = messageHistory.records.first else {
            return XCTFail("Expected a persisted message record.")
        }

        try await runtime.redactHistoryItems([firstMessage.id], in: thread.id)

        let reloadedAfterRedaction = try makeHistoryRuntime(
            backend: InMemoryAgentBackend(),
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: try GRDBRuntimeStateStore(url: url)
        )
        let redactedHistory = try await reloadedAfterRedaction.execute(
            HistoryItemsQuery(threadID: thread.id, kinds: [.message])
        )

        guard let redactedRecord = redactedHistory.records.first(where: { $0.id == firstMessage.id }) else {
            return XCTFail("Expected the redacted record to still be queryable.")
        }
        XCTAssertNotNil(redactedRecord.redaction)

        try await reloadedAfterRedaction.deleteThread(id: thread.id)

        let deletedRuntime = try makeHistoryRuntime(
            backend: InMemoryAgentBackend(),
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: try GRDBRuntimeStateStore(url: url)
        )
        let threads = try await deletedRuntime.execute(
            ThreadMetadataQuery(threadIDs: [thread.id])
        )
        XCTAssertTrue(threads.isEmpty)
    }

    func testGRDBRuntimeStateStoreImportsLegacyFileStateOnFirstPrepare() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let legacyURL = directory.appendingPathComponent("runtime-state").appendingPathExtension("json")
        let sqliteURL = directory.appendingPathComponent("runtime-state").appendingPathExtension("sqlite")

        let backend = InMemoryAgentBackend(
            structuredResponseText: #"{"reply":"Legacy import payload.","priority":"normal"}"#
        )
        let legacyRuntime = try makeHistoryRuntime(
            backend: backend,
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: FileRuntimeStateStore(url: legacyURL)
        )

        _ = try await legacyRuntime.restore()
        _ = try await legacyRuntime.signIn()

        let thread = try await legacyRuntime.createThread(title: "Legacy File Thread")
        _ = try await legacyRuntime.sendMessage(
            UserMessageRequest(text: "Create a legacy payload."),
            in: thread.id,
            expecting: ShippingReplyDraft.self
        )

        let importedStore = try GRDBRuntimeStateStore(url: sqliteURL)
        let importedRuntime = try makeHistoryRuntime(
            backend: backend,
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: importedStore
        )

        _ = try await importedRuntime.prepareStore()

        let summary = try await importedRuntime.fetchThreadSummary(id: thread.id)
        XCTAssertEqual(summary.latestStructuredOutputMetadata?.formatName, "shipping_reply_draft")

        let history = try await importedRuntime.execute(
            HistoryItemsQuery(threadID: thread.id, kinds: [.message, .structuredOutput])
        )
        XCTAssertFalse(history.records.isEmpty)
    }

    func testGRDBRuntimeStateStoreExternalizesImageAttachments() async throws {
        let url = temporaryRuntimeSQLiteURL()
        let attachmentsDirectory = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.deletingPathExtension().lastPathComponent).codexkit-state", isDirectory: true)
            .appendingPathComponent("attachments", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: attachmentsDirectory.deletingLastPathComponent())
        }

        let imageData = Data([0x89, 0x50, 0x4E, 0x47, 0xDE, 0xAD, 0xBE, 0xEF])
        let runtime = try makeHistoryRuntime(
            backend: InMemoryAgentBackend(),
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: try GRDBRuntimeStateStore(url: url)
        )

        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread(title: "Attachment Thread")
        _ = try await runtime.sendMessage(
            UserMessageRequest(
                text: "here is an image",
                images: [.png(imageData)]
            ),
            in: thread.id
        )

        let reloadedRuntime = try makeHistoryRuntime(
            backend: InMemoryAgentBackend(),
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: try GRDBRuntimeStateStore(url: url)
        )

        let history = try await reloadedRuntime.execute(
            HistoryItemsQuery(threadID: thread.id, kinds: [.message])
        )
        guard let userMessage = history.records.compactMap({ record -> AgentMessage? in
            guard case let .message(message) = record.item, message.role == .user else {
                return nil
            }
            return message
        }).first else {
            return XCTFail("Expected a persisted user message with an attachment.")
        }

        XCTAssertEqual(userMessage.images.count, 1)
        XCTAssertEqual(userMessage.images.first?.data, imageData)

        let attachmentFiles = try FileManager.default.contentsOfDirectory(
            at: attachmentsDirectory.appendingPathComponent(thread.id, isDirectory: true)
                .appendingPathComponent(userMessage.id, isDirectory: true),
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(attachmentFiles.count, 1)

        let databaseData = try Data(contentsOf: url)
        XCTAssertNil(databaseData.range(of: imageData.base64EncodedData()))
    }

    func testManualCompactionPreservesVisibleHistoryAndHidesMarkersByDefault() async throws {
        let backend = CompactingTestBackend()
        let runtime = try makeHistoryRuntime(
            backend: backend,
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: InMemoryRuntimeStateStore(),
            contextCompaction: AgentContextCompactionConfiguration(
                isEnabled: true,
                mode: .automatic
            )
        )

        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread(title: "Compaction")
        _ = try await runtime.sendMessage(UserMessageRequest(text: "one"), in: thread.id)
        _ = try await runtime.sendMessage(UserMessageRequest(text: "two"), in: thread.id)
        _ = try await runtime.sendMessage(UserMessageRequest(text: "three"), in: thread.id)

        let visibleBefore = await runtime.messages(for: thread.id)
        XCTAssertEqual(visibleBefore.count, 6)

        let contextState = try await runtime.compactThreadContext(id: thread.id)
        XCTAssertEqual(contextState.generation, 1)
        XCTAssertLessThan(contextState.effectiveMessages.count, visibleBefore.count)

        let visibleAfter = await runtime.messages(for: thread.id)
        XCTAssertEqual(visibleAfter, visibleBefore)

        let hiddenHistory = try await runtime.execute(
            HistoryItemsQuery(
                threadID: thread.id,
                kinds: [.systemEvent]
            )
        )
        XCTAssertFalse(hiddenHistory.records.contains(where: { $0.item.isCompactionMarker }))

        let debugHistory = try await runtime.execute(
            HistoryItemsQuery(
                threadID: thread.id,
                kinds: [.systemEvent],
                includeCompactionEvents: true
            )
        )
        XCTAssertTrue(debugHistory.records.contains(where: { $0.item.isCompactionMarker }))
    }

    func testAutomaticRetryCompactionRecoversFromContextLimitError() async throws {
        let backend = CompactingTestBackend(failOnHistoryCountAbove: 2)
        let runtime = try makeHistoryRuntime(
            backend: backend,
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: InMemoryRuntimeStateStore(),
            contextCompaction: AgentContextCompactionConfiguration(
                isEnabled: true,
                mode: .automatic,
                trigger: AgentContextCompactionTrigger(
                    estimatedTokenThreshold: 100_000,
                    retryOnContextLimitError: true
                )
            )
        )

        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread(title: "Retry Compact")
        _ = try await runtime.sendMessage(UserMessageRequest(text: "one"), in: thread.id)
        _ = try await runtime.sendMessage(UserMessageRequest(text: "two"), in: thread.id)
        _ = try await runtime.sendMessage(UserMessageRequest(text: "three"), in: thread.id)
        let reply = try await runtime.sendMessage(UserMessageRequest(text: "four"), in: thread.id)

        XCTAssertEqual(reply, "Echo: four")
        let compactCallCount = await backend.compactCallCount()
        let beginTurnHistoryCounts = await backend.beginTurnHistoryCounts()
        XCTAssertEqual(compactCallCount, 1)
        XCTAssertGreaterThanOrEqual(beginTurnHistoryCounts.count, 5)
    }

    func testContextStatePersistsAcrossGRDBReload() async throws {
        let url = temporaryRuntimeSQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let backend = CompactingTestBackend()
        let runtime = try makeHistoryRuntime(
            backend: backend,
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: try GRDBRuntimeStateStore(url: url),
            contextCompaction: AgentContextCompactionConfiguration(
                isEnabled: true,
                mode: .automatic
            )
        )

        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread(title: "Persisted Context")
        _ = try await runtime.sendMessage(UserMessageRequest(text: "alpha"), in: thread.id)
        _ = try await runtime.sendMessage(UserMessageRequest(text: "beta"), in: thread.id)
        _ = try await runtime.compactThreadContext(id: thread.id)

        let reloadedRuntime = try makeHistoryRuntime(
            backend: backend,
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: try GRDBRuntimeStateStore(url: url),
            contextCompaction: AgentContextCompactionConfiguration(
                isEnabled: true,
                mode: .automatic
            )
        )

        let restoredContext = try await reloadedRuntime.fetchThreadContextState(id: thread.id)
        XCTAssertEqual(restoredContext?.generation, 1)
        XCTAssertFalse(restoredContext?.effectiveMessages.isEmpty ?? true)
    }

    func testContextCompactionConfigurationDefaultsAndCodableShape() throws {
        let configuration = AgentContextCompactionConfiguration()
        XCTAssertFalse(configuration.isEnabled)
        XCTAssertEqual(configuration.mode, .automatic)

        let encoded = try JSONEncoder().encode(
            AgentContextCompactionConfiguration(isEnabled: true, mode: .manual)
        )
        let decoded = try JSONDecoder().decode(
            AgentContextCompactionConfiguration.self,
            from: encoded
        )

        XCTAssertTrue(decoded.isEnabled)
        XCTAssertEqual(decoded.mode, .manual)
    }
}

private func makeHistoryRuntime(
    backend: any AgentBackend,
    approvalPresenter: any ApprovalPresenting,
    stateStore: any RuntimeStateStoring,
    tools: [AgentRuntime.ToolRegistration] = [],
    contextCompaction: AgentContextCompactionConfiguration = AgentContextCompactionConfiguration()
) throws -> AgentRuntime {
    try AgentRuntime(configuration: .init(
        authProvider: DemoChatGPTAuthProvider(),
        secureStore: KeychainSessionSecureStore(
            service: "CodexKitTests.ChatGPTSession",
            account: UUID().uuidString
        ),
        backend: backend,
        approvalPresenter: approvalPresenter,
        stateStore: stateStore,
        tools: tools,
        contextCompaction: contextCompaction
    ))
}

private func temporaryRuntimeSQLiteURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("sqlite")
}

private func messageTexts(in page: AgentThreadHistoryPage) -> [String] {
    page.items.compactMap { item in
        guard case let .message(message) = item else {
            return nil
        }
        return message.displayText
    }
}

private func waitUntil(
    timeoutNanoseconds: UInt64 = 2_000_000_000,
    intervalNanoseconds: UInt64 = 20_000_000,
    condition: @escaping @Sendable () async throws -> Bool
) async throws {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while DispatchTime.now().uptimeNanoseconds < deadline {
        if try await condition() {
            return
        }
        try await Task.sleep(nanoseconds: intervalNanoseconds)
    }

    XCTFail("Timed out waiting for condition.")
}

private actor ToolExecutionGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var released = false

    func wait() async {
        guard !released else {
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        released = true
        let continuations = waiters
        waiters.removeAll()
        continuations.forEach { $0.resume() }
    }
}

private actor PartialEmissionGate {
    private var partialEmitted = false
    private var partialWaiters: [CheckedContinuation<Void, Never>] = []
    private var commitReleased = false
    private var commitWaiters: [CheckedContinuation<Void, Never>] = []

    func markPartialEmitted() {
        partialEmitted = true
        let continuations = partialWaiters
        partialWaiters.removeAll()
        continuations.forEach { $0.resume() }
    }

    func waitForPartialEmission() async {
        guard !partialEmitted else {
            return
        }

        await withCheckedContinuation { continuation in
            partialWaiters.append(continuation)
        }
    }

    func waitForCommitRelease() async {
        guard !commitReleased else {
            return
        }

        await withCheckedContinuation { continuation in
            commitWaiters.append(continuation)
        }
    }

    func releaseCommit() {
        commitReleased = true
        let continuations = commitWaiters
        commitWaiters.removeAll()
        continuations.forEach { $0.resume() }
    }
}

private actor CompactingTestBackend: AgentBackend, AgentBackendContextCompacting {
    nonisolated let baseInstructions: String? = nil

    private let failOnHistoryCountAbove: Int?
    private var threads: [String: AgentThread] = [:]
    private var compactCalls = 0
    private var historyCounts: [Int] = []

    init(failOnHistoryCountAbove: Int? = nil) {
        self.failOnHistoryCountAbove = failOnHistoryCountAbove
    }

    func createThread(session _: ChatGPTSession) async throws -> AgentThread {
        let thread = AgentThread(id: UUID().uuidString)
        threads[thread.id] = thread
        return thread
    }

    func resumeThread(id: String, session _: ChatGPTSession) async throws -> AgentThread {
        if let thread = threads[id] {
            return thread
        }
        let thread = AgentThread(id: id)
        threads[id] = thread
        return thread
    }

    func beginTurn(
        thread: AgentThread,
        history: [AgentMessage],
        message: UserMessageRequest,
        instructions _: String,
        responseFormat _: AgentStructuredOutputFormat?,
        streamedStructuredOutput _: AgentStreamedStructuredOutputRequest?,
        tools _: [ToolDefinition],
        session _: ChatGPTSession
    ) async throws -> any AgentTurnStreaming {
        historyCounts.append(history.count)
        if let failOnHistoryCountAbove,
           history.count > failOnHistoryCountAbove,
           !history.contains(where: { $0.role == .system && $0.text.contains("Compacted conversation summary") }) {
            throw AgentRuntimeError(
                code: "context_limit_exceeded",
                message: "Maximum context length exceeded."
            )
        }

        return MockAgentTurnSession(
            thread: thread,
            message: message,
            selectedTool: nil,
            structuredResponseText: nil,
            streamedStructuredOutput: nil
        )
    }

    func compactContext(
        thread: AgentThread,
        effectiveHistory: [AgentMessage],
        instructions _: String,
        tools _: [ToolDefinition],
        session _: ChatGPTSession
    ) async throws -> AgentCompactionResult {
        compactCalls += 1
        let lastUser = effectiveHistory.last(where: { $0.role == .user })
        let lastAssistant = effectiveHistory.last(where: { $0.role == .assistant })
        var compacted = [
            AgentMessage(
                threadID: thread.id,
                role: .system,
                text: "Compacted conversation summary"
            ),
        ]
        if let lastUser {
            compacted.append(lastUser)
        }
        if let lastAssistant {
            compacted.append(lastAssistant)
        }
        return AgentCompactionResult(
            effectiveMessages: compacted,
            summaryPreview: "Compacted conversation summary"
        )
    }

    func compactCallCount() -> Int {
        compactCalls
    }

    func beginTurnHistoryCounts() -> [Int] {
        historyCounts
    }
}

private actor BlockingStructuredPartialBackend: AgentBackend {
    private let gate = PartialEmissionGate()
    private var latestThreadID: String?

    func createThread(session _: ChatGPTSession) async throws -> AgentThread {
        AgentThread(id: UUID().uuidString)
    }

    func resumeThread(id: String, session _: ChatGPTSession) async throws -> AgentThread {
        AgentThread(id: id)
    }

    func beginTurn(
        thread: AgentThread,
        history _: [AgentMessage],
        message _: UserMessageRequest,
        instructions _: String,
        responseFormat _: AgentStructuredOutputFormat?,
        streamedStructuredOutput _: AgentStreamedStructuredOutputRequest?,
        tools _: [ToolDefinition],
        session _: ChatGPTSession
    ) async throws -> any AgentTurnStreaming {
        latestThreadID = thread.id
        return BlockingStructuredPartialTurnSession(
            threadID: thread.id,
            gate: gate
        )
    }

    func waitForPartialEmission() async {
        await gate.waitForPartialEmission()
    }

    func releaseCommit() async {
        await gate.releaseCommit()
    }
}

private final class BlockingStructuredPartialTurnSession: AgentTurnStreaming, @unchecked Sendable {
    let events: AsyncThrowingStream<AgentBackendEvent, Error>

    init(threadID: String, gate: PartialEmissionGate) {
        let turn = AgentTurn(id: UUID().uuidString, threadID: threadID)
        let payload: JSONValue = .object([
            "reply": .string("Your order is already in transit."),
            "priority": .string("high"),
        ])

        events = AsyncThrowingStream { continuation in
            Task {
                continuation.yield(.turnStarted(turn))
                continuation.yield(
                    .assistantMessageDelta(
                        threadID: threadID,
                        turnID: turn.id,
                        delta: "Echo: Draft a shipping reply."
                    )
                )
                continuation.yield(.structuredOutputPartial(payload))
                await gate.markPartialEmitted()
                await gate.waitForCommitRelease()
                continuation.yield(.structuredOutputCommitted(payload))
                continuation.yield(
                    .assistantMessageCompleted(
                        AgentMessage(
                            threadID: threadID,
                            role: .assistant,
                            text: "Echo: Draft a shipping reply.",
                            structuredOutput: AgentStructuredOutputMetadata(
                                formatName: "shipping_reply_draft",
                                payload: payload
                            )
                        )
                    )
                )
                continuation.yield(
                    .turnCompleted(
                        AgentTurnSummary(
                            threadID: threadID,
                            turnID: turn.id,
                            usage: AgentUsage(inputTokens: 1, outputTokens: 1)
                        )
                    )
                )
                continuation.finish()
            }
        }
    }

    func submitToolResult(_: ToolResultEnvelope, for _: String) async throws {}
}
