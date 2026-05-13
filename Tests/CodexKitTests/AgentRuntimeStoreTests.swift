@testable import CodexKit
import CodexKitUI
import XCTest

@MainActor
final class AgentRuntimeStoreTests: XCTestCase {
    func testStoreRestoresSignsInAndStreamsMessages() async throws {
        let runtime = try AgentRuntime(configuration: .init(
            authProvider: DemoChatGPTAuthProvider(),
            secureStore: KeychainSessionSecureStore(
                service: "CodexKitTests.ChatGPTSession",
                account: UUID().uuidString
            ),
            backend: InMemoryAgentBackend(),
            approvalPresenter: ApprovalInbox(),
            stateStore: InMemoryRuntimeStateStore()
        ))

        let store = AgentRuntimeStore(runtime: runtime)

        await store.restore()
        XCTAssertNil(store.session)

        await store.signIn()
        XCTAssertEqual(store.session?.account.email, "demo@example.com")

        await store.send("hello")

        XCTAssertEqual(store.messages.filter { $0.role == .user }.count, 1)
        XCTAssertEqual(store.messages.filter { $0.role == .assistant }.count, 1)
        XCTAssertTrue(store.streamingText.isEmpty)
        XCTAssertNil(store.lastError)
    }

    func testRuntimeCoalescesRedundantPendingStoreOperations() async throws {
        let stateStore = RecordingRuntimeStateStore()
        let runtime = try AgentRuntime(configuration: .init(
            authProvider: DemoChatGPTAuthProvider(),
            secureStore: KeychainSessionSecureStore(
                service: "CodexKitTests.ChatGPTSession",
                account: UUID().uuidString
            ),
            backend: InMemoryAgentBackend(),
            approvalPresenter: ApprovalInbox(),
            stateStore: stateStore
        ))

        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread(title: "Coalescing")
        _ = try await runtime.send(Request(text: "hello"), in: thread.id)

        let batches = await stateStore.appliedOperationBatches()
        XCTAssertFalse(batches.isEmpty)
        for batch in batches {
            XCTAssertLessThanOrEqual(maxUpsertThreadCountPerThread(in: batch), 1)
            XCTAssertLessThanOrEqual(maxUpsertSummaryCountPerThread(in: batch), 1)
        }
    }

    func testCoalescedStoreOperationsPreserveFinalStateSemantics() async throws {
        let runtime = try makeRuntime()
        let initialState = StoredRuntimeState(threads: [
            makeThread(id: "thread-live", title: "Live"),
            makeThread(id: "thread-deleted", title: "Deleted"),
        ])
        let operations = makeRepresentativeStoreOperations()

        let uncoalescedState = try initialState.applying(operations)
        let coalesced = await runtime.coalescedStoreOperations(operations)
        let coalescedState = try initialState.applying(coalesced)

        XCTAssertEqual(
            normalizedRedactionDates(in: coalescedState),
            normalizedRedactionDates(in: uncoalescedState)
        )
        XCTAssertLessThan(coalesced.count, operations.count)
        XCTAssertEqual(
            coalesced.filter {
                if case .appendHistoryItems = $0 {
                    return true
                }
                return false
            }.count,
            2
        )
        XCTAssertTrue(coalesced.contains(.deleteThread(threadID: "thread-deleted")))
    }

    private func maxUpsertThreadCountPerThread(
        in operations: [AgentStoreWriteOperation]
    ) -> Int {
        let counts = Dictionary(
            operations.compactMap { operation -> String? in
                guard case let .upsertThread(thread) = operation else {
                    return nil
                }
                return thread.id
            }.map { ($0, 1) },
            uniquingKeysWith: +
        )
        return counts.values.max() ?? 0
    }

    private func maxUpsertSummaryCountPerThread(
        in operations: [AgentStoreWriteOperation]
    ) -> Int {
        let counts = Dictionary(
            operations.compactMap { operation -> String? in
                guard case let .upsertSummary(threadID, _) = operation else {
                    return nil
                }
                return threadID
            }.map { ($0, 1) },
            uniquingKeysWith: +
        )
        return counts.values.max() ?? 0
    }

    private func makeRuntime() throws -> AgentRuntime {
        try AgentRuntime(configuration: .init(
            authProvider: DemoChatGPTAuthProvider(),
            secureStore: KeychainSessionSecureStore(
                service: "CodexKitTests.ChatGPTSession",
                account: UUID().uuidString
            ),
            backend: InMemoryAgentBackend(),
            approvalPresenter: ApprovalInbox(),
            stateStore: InMemoryRuntimeStateStore()
        ))
    }

    private func normalizedRedactionDates(
        in state: StoredRuntimeState
    ) -> StoredRuntimeState {
        let fixedRedactionDate = Date(timeIntervalSince1970: 10)
        let historyByThread = state.historyByThread.mapValues { records in
            records.map { record in
                guard let redaction = record.redaction else {
                    return record
                }
                return AgentHistoryRecord(
                    id: record.id,
                    sequenceNumber: record.sequenceNumber,
                    createdAt: record.createdAt,
                    item: record.item,
                    redaction: AgentHistoryRedaction(
                        redactedAt: fixedRedactionDate,
                        reason: redaction.reason
                    )
                )
            }
        }

        return StoredRuntimeState(
            threads: state.threads,
            messagesByThread: state.messagesByThread,
            historyByThread: historyByThread,
            summariesByThread: state.summariesByThread,
            contextStateByThread: state.contextStateByThread,
            nextHistorySequenceByThread: state.nextHistorySequenceByThread
        )
    }

    private func makeRepresentativeStoreOperations() -> [AgentStoreWriteOperation] {
        let liveThreadID = "thread-live"
        let deletedThreadID = "thread-deleted"
        let firstMessage = makeHistoryRecord(
            id: "record-1",
            sequenceNumber: 1,
            threadID: liveThreadID,
            text: "First"
        )
        let secondMessage = makeHistoryRecord(
            id: "record-2",
            sequenceNumber: 2,
            threadID: liveThreadID,
            text: "Second"
        )
        let deletedMessage = makeHistoryRecord(
            id: "deleted-record",
            sequenceNumber: 1,
            threadID: deletedThreadID,
            text: "Deleted"
        )

        return [
            .upsertThread(makeThread(id: liveThreadID, title: "Live draft")),
            .upsertThread(makeThread(id: liveThreadID, title: "Live final")),
            .upsertSummary(threadID: liveThreadID, summary: makeSummary(threadID: liveThreadID, preview: "Draft")),
            .upsertSummary(threadID: liveThreadID, summary: makeSummary(threadID: liveThreadID, preview: "Final")),
            .upsertThreadContextState(
                threadID: liveThreadID,
                state: makeContextState(threadID: liveThreadID, text: "Old context")
            ),
            .upsertThreadContextState(
                threadID: liveThreadID,
                state: makeContextState(threadID: liveThreadID, text: "New context")
            ),
            .appendHistoryItems(threadID: liveThreadID, items: [firstMessage]),
            .appendHistoryItems(threadID: liveThreadID, items: [secondMessage]),
            .redactHistoryItems(
                threadID: liveThreadID,
                itemIDs: [firstMessage.id],
                reason: AgentRedactionReason(code: "test")
            ),
            .upsertThread(makeThread(id: deletedThreadID, title: "Delete draft")),
            .upsertSummary(threadID: deletedThreadID, summary: makeSummary(threadID: deletedThreadID, preview: "Delete draft")),
            .appendHistoryItems(threadID: deletedThreadID, items: [deletedMessage]),
            .deleteThread(threadID: deletedThreadID),
        ]
    }

    private func makeThread(id: String, title: String) -> AgentThread {
        AgentThread(
            id: id,
            title: title,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2)
        )
    }

    private func makeSummary(
        threadID: String,
        preview: String
    ) -> AgentThreadSummary {
        AgentThreadSummary(
            threadID: threadID,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            latestAssistantMessagePreview: preview
        )
    }

    private func makeContextState(
        threadID: String,
        text: String
    ) -> AgentThreadContextState {
        AgentThreadContextState(
            threadID: threadID,
            effectiveMessages: [
                AgentMessage(
                    id: "\(threadID)-context-message",
                    threadID: threadID,
                    role: .system,
                    text: text,
                    createdAt: Date(timeIntervalSince1970: 3)
                )
            ],
            generation: 1
        )
    }

    private func makeHistoryRecord(
        id: String,
        sequenceNumber: Int,
        threadID: String,
        text: String
    ) -> AgentHistoryRecord {
        AgentHistoryRecord(
            id: id,
            sequenceNumber: sequenceNumber,
            createdAt: Date(timeIntervalSince1970: TimeInterval(sequenceNumber)),
            item: .message(AgentMessage(
                id: "\(id)-message",
                threadID: threadID,
                role: .assistant,
                text: text,
                createdAt: Date(timeIntervalSince1970: TimeInterval(sequenceNumber))
            ))
        )
    }
}

private actor RecordingRuntimeStateStore: RuntimeStateStoring {
    private let backingStore = InMemoryRuntimeStateStore()
    private var operationBatches: [[AgentStoreWriteOperation]] = []

    func loadState() async throws -> StoredRuntimeState {
        try await backingStore.loadState()
    }

    func saveState(_ state: StoredRuntimeState) async throws {
        try await backingStore.saveState(state)
    }

    func prepare() async throws -> AgentStoreMetadata {
        try await backingStore.prepare()
    }

    func readMetadata() async throws -> AgentStoreMetadata {
        try await backingStore.readMetadata()
    }

    func apply(_ operations: [AgentStoreWriteOperation]) async throws {
        operationBatches.append(operations)
        try await backingStore.apply(operations)
    }

    func appliedOperationBatches() -> [[AgentStoreWriteOperation]] {
        operationBatches
    }
}
