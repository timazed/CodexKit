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

}
