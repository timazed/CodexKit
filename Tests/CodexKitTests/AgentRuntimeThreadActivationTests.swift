@testable import CodexKit
@testable import CodexKitSQLite
import Combine
import XCTest

extension AgentRuntimeTests {
    func testSQLiteColdResumeRestoresSequenceAndBoundedContext() async throws {
        let url = temporaryRuntimeSQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let backend = InMemoryAgentBackend()
        let firstRuntime = try makeHistoryRuntime(
            backend: backend,
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: try SQLiteRuntimeStateStore(url: url),
            threadActivationPolicy: .init(
                maximumMessageCount: 6,
                maximumEstimatedTokens: 2_000,
                maximumHistoryRecordCount: 64
            )
        )
        _ = try await firstRuntime.restore()
        _ = try await firstRuntime.useSession(demoSession())
        let thread = try await firstRuntime.createThread(title: "Cold resume")
        _ = try await firstRuntime.send(Request(text: "alpha"), in: thread.id)
        _ = try await firstRuntime.send(Request(text: "beta"), in: thread.id)

        let beforeResume = try await firstRuntime.execute(
            HistoryItemsQuery(threadID: thread.id)
        )
        let persistedMaximum = try XCTUnwrap(beforeResume.records.last?.sequenceNumber)

        let resumedRuntime = try makeHistoryRuntime(
            backend: backend,
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: try SQLiteRuntimeStateStore(url: url),
            threadActivationPolicy: .init(
                maximumMessageCount: 6,
                maximumEstimatedTokens: 2_000,
                maximumHistoryRecordCount: 64
            )
        )
        let restored = try await resumedRuntime.restore()
        XCTAssertTrue(restored.threads.isEmpty)
        let initialActiveCount = await resumedRuntime.activeThreadCount()
        XCTAssertEqual(initialActiveCount, 0)
        _ = try await resumedRuntime.useSession(demoSession())

        _ = try await resumedRuntime.resumeThread(id: thread.id)
        let resumedActiveCount = await resumedRuntime.activeThreadCount()
        XCTAssertEqual(resumedActiveCount, 1)

        let afterResume = try await resumedRuntime.execute(
            HistoryItemsQuery(threadID: thread.id)
        )
        XCTAssertEqual(afterResume.records.last?.sequenceNumber, persistedMaximum + 1)

        _ = try await resumedRuntime.send(Request(text: "gamma"), in: thread.id)
        let receivedHistory = await backend.receivedHistoryTexts()
        let latestHistory = try XCTUnwrap(receivedHistory.last)
        XCTAssertTrue(latestHistory.contains("alpha"))
        XCTAssertTrue(latestHistory.contains("Echo: alpha"))
        XCTAssertTrue(latestHistory.contains("beta"))
        XCTAssertTrue(latestHistory.contains("Echo: beta"))
        XCTAssertLessThanOrEqual(latestHistory.count, 6)
    }

    func testSQLiteActivationIsThreadScopedAndTurnClosed() async throws {
        let url = temporaryRuntimeSQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let selected = AgentThread(id: "selected")
        let history = (0 ..< 50).flatMap { turn -> [AgentHistoryRecord] in
            let userSequence = (turn * 2) + 1
            let assistantSequence = userSequence + 1
            return [
                AgentHistoryRecord(
                    sequenceNumber: userSequence,
                    createdAt: Date(timeIntervalSince1970: Double(userSequence)),
                    item: .message(AgentMessage(
                        threadID: selected.id,
                        role: .user,
                        text: "question \(turn)",
                        createdAt: Date(timeIntervalSince1970: Double(userSequence))
                    ))
                ),
                AgentHistoryRecord(
                    sequenceNumber: assistantSequence,
                    createdAt: Date(timeIntervalSince1970: Double(assistantSequence)),
                    item: .message(AgentMessage(
                        threadID: selected.id,
                        role: .assistant,
                        text: "answer \(turn)",
                        createdAt: Date(timeIntervalSince1970: Double(assistantSequence))
                    ))
                ),
            ]
        } + [
            AgentHistoryRecord(
                sequenceNumber: 101,
                createdAt: Date(timeIntervalSince1970: 101),
                item: .message(AgentMessage(
                    threadID: selected.id,
                    role: .user,
                    text: "incomplete question",
                    createdAt: Date(timeIntervalSince1970: 101)
                ))
            ),
        ]
        let unrelatedThreads = (0 ..< 20).map { AgentThread(id: "unrelated-\($0)") }
        let unrelatedHistoryByThread = Dictionary(
            uniqueKeysWithValues: unrelatedThreads.map { thread in
                let records = (1 ... 200).map { sequence in
                    AgentHistoryRecord(
                        sequenceNumber: sequence,
                        createdAt: Date(timeIntervalSince1970: Double(sequence)),
                        item: .systemEvent(AgentSystemEventRecord(
                            type: .threadStatusChanged,
                            threadID: thread.id,
                            status: .idle,
                            occurredAt: Date(timeIntervalSince1970: Double(sequence))
                        ))
                    )
                }
                return (thread.id, records)
            }
        )
        let store = try SQLiteRuntimeStateStore(url: url)
        try await store.saveState(StoredRuntimeState(
            threads: [selected] + unrelatedThreads,
            historyByThread: unrelatedHistoryByThread.merging(
                [selected.id: history],
                uniquingKeysWith: { selected, _ in selected }
            )
        ))

        await store.resetActivationDiagnostics()
        let activation = try await store.loadThreadActivationState(
            id: selected.id,
            policy: .init(
                maximumMessageCount: 2,
                maximumEstimatedTokens: 100,
                maximumHistoryRecordCount: 16
            )
        )
        XCTAssertEqual(activation.thread.id, selected.id)
        XCTAssertEqual(activation.nextHistorySequence, 102)
        XCTAssertEqual(
            activation.effectiveMessages.map(\.text),
            ["question 49", "answer 49"]
        )
        let firstDiagnostics = await store.activationDiagnostics()
        let firstMetrics = try XCTUnwrap(firstDiagnostics.latestActivation)
        XCTAssertEqual(firstMetrics.fetchedHistoryRowCount, 16)
        XCTAssertEqual(firstMetrics.decodedHistoryRowCount, 16)
        XCTAssertGreaterThan(firstMetrics.decodedHistoryByteCount, 0)

        let extraThread = AgentThread(id: "unrelated-extra")
        let extraHistory = (1 ... 2_000).map { sequence in
            AgentHistoryRecord(
                sequenceNumber: sequence,
                createdAt: Date(timeIntervalSince1970: Double(sequence)),
                item: .systemEvent(AgentSystemEventRecord(
                    type: .threadStatusChanged,
                    threadID: extraThread.id,
                    status: .idle,
                    occurredAt: Date(timeIntervalSince1970: Double(sequence))
                ))
            )
        }
        try await store.apply([.upsertThread(extraThread)])
        for start in stride(
            from: 0,
            to: extraHistory.count,
            by: AgentStoreLimits.maximumHistoryWriteCount
        ) {
            let end = min(start + AgentStoreLimits.maximumHistoryWriteCount, extraHistory.count)
            try await store.apply([.appendHistoryItems(
                threadID: extraThread.id,
                items: Array(extraHistory[start ..< end])
            )])
        }
        _ = try await store.loadThreadActivationState(
            id: selected.id,
            policy: .init(
                maximumMessageCount: 2,
                maximumEstimatedTokens: 100,
                maximumHistoryRecordCount: 16
            )
        )
        let secondDiagnostics = await store.activationDiagnostics()
        let secondMetrics = try XCTUnwrap(secondDiagnostics.latestActivation)
        XCTAssertEqual(secondMetrics, firstMetrics)

        let queryPlan = try await store.activationHistoryQueryPlan(
            threadID: selected.id,
            limit: 17
        )
        XCTAssertTrue(
            queryPlan.contains { $0.contains("runtime_history_thread_sequence") },
            queryPlan.joined(separator: "\n")
        )
    }

    func testSQLiteLazyRestoreDecodesZeroHistoryBodies() async throws {
        let url = temporaryRuntimeSQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let thread = AgentThread(id: "startup-history")
        let history = (1 ... 1_000).map { sequence in
            AgentHistoryRecord(
                sequenceNumber: sequence,
                createdAt: Date(timeIntervalSince1970: Double(sequence)),
                item: .systemEvent(AgentSystemEventRecord(
                    type: .threadStatusChanged,
                    threadID: thread.id,
                    status: .idle,
                    occurredAt: Date(timeIntervalSince1970: Double(sequence))
                ))
            )
        }
        let store = try SQLiteRuntimeStateStore(url: url)
        try await store.saveState(StoredRuntimeState(
            threads: [thread],
            historyByThread: [thread.id: history]
        ))
        await store.resetActivationDiagnostics()

        let runtime = try makeHistoryRuntime(
            backend: InMemoryAgentBackend(),
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: store
        )
        let restored = try await runtime.restore()
        XCTAssertTrue(restored.threads.isEmpty)

        let persistedThreads = try await runtime.persistedThreads()
        XCTAssertEqual(persistedThreads.map(\.id), [thread.id])

        let diagnostics = await store.activationDiagnostics()
        XCTAssertEqual(diagnostics.decodedHistoryBodyCount, 0)
        XCTAssertNil(diagnostics.latestActivation)
    }

    func testFailedAppendDoesNotPoisonAnUnrelatedSQLiteThread() async throws {
        let url = temporaryRuntimeSQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try FailOnceRuntimeStateStore(base: SQLiteRuntimeStateStore(url: url))
        let runtime = try makeHistoryRuntime(
            backend: InMemoryAgentBackend(),
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: store
        )
        _ = try await runtime.restore()
        _ = try await runtime.useSession(demoSession())
        let firstThread = try await runtime.createThread(title: "Will fail")

        await store.failNextHistoryAppend()
        do {
            _ = try await runtime.send(Request(text: "must not persist"), in: firstThread.id)
            XCTFail("Expected the injected persistence failure.")
        } catch let error as InjectedRuntimeStoreError {
            XCTAssertEqual(error, .appendFailed)
        }

        let secondThread = try await runtime.createThread(title: "Must succeed")
        _ = try await runtime.send(Request(text: "healthy"), in: secondThread.id)

        let firstHistory = try await store.execute(
            HistoryItemsQuery(threadID: firstThread.id, kinds: [.message])
        )
        let secondHistory = try await store.execute(
            HistoryItemsQuery(threadID: secondThread.id, kinds: [.message])
        )
        XCTAssertFalse(firstHistory.records.contains { record in
            guard case let .message(message) = record.item else { return false }
            return message.text == "must not persist"
        })
        XCTAssertTrue(secondHistory.records.contains { record in
            guard case let .message(message) = record.item else { return false }
            return message.text == "healthy"
        })
        XCTAssertTrue(secondHistory.records.allSatisfy { record in
            guard case let .message(message) = record.item else { return false }
            return message.threadID == secondThread.id
        })
    }

    func testSQLiteActivationPreservesCompleteToolAndStructuredRelationships() async throws {
        let url = temporaryRuntimeSQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let thread = AgentThread(id: "relationships")
        let pairedInvocation = ToolInvocation(
            id: "paired-call",
            threadID: thread.id,
            turnID: "turn-1",
            toolName: "lookup",
            arguments: .object(["query": .string("status")])
        )
        let orphanedInvocation = ToolInvocation(
            id: "orphaned-call",
            threadID: thread.id,
            turnID: "turn-2",
            toolName: "must_not_appear",
            arguments: .object([:])
        )
        let structuredMetadata = AgentStructuredOutputMetadata(
            formatName: "status_payload",
            payload: .object(["status": .string("ready")])
        )
        let assistant = AgentMessage(
            id: "assistant-with-structure",
            threadID: thread.id,
            role: .assistant,
            text: "The status is ready.",
            structuredOutput: structuredMetadata,
            createdAt: Date(timeIntervalSince1970: 4)
        )
        let records = [
            AgentHistoryRecord(
                sequenceNumber: 1,
                createdAt: Date(timeIntervalSince1970: 1),
                item: .message(AgentMessage(
                    threadID: thread.id,
                    role: .user,
                    text: "Check status",
                    createdAt: Date(timeIntervalSince1970: 1)
                ))
            ),
            AgentHistoryRecord(
                sequenceNumber: 2,
                createdAt: Date(timeIntervalSince1970: 2),
                item: .toolCall(AgentToolCallRecord(invocation: pairedInvocation))
            ),
            AgentHistoryRecord(
                sequenceNumber: 3,
                createdAt: Date(timeIntervalSince1970: 3),
                item: .toolResult(AgentToolResultRecord(
                    threadID: thread.id,
                    turnID: pairedInvocation.turnID,
                    result: .success(invocation: pairedInvocation, text: "ready"),
                    completedAt: Date(timeIntervalSince1970: 3)
                ))
            ),
            AgentHistoryRecord(
                sequenceNumber: 4,
                createdAt: Date(timeIntervalSince1970: 4),
                item: .message(assistant)
            ),
            AgentHistoryRecord(
                sequenceNumber: 5,
                createdAt: Date(timeIntervalSince1970: 4),
                item: .structuredOutput(AgentStructuredOutputRecord(
                    threadID: thread.id,
                    turnID: pairedInvocation.turnID,
                    messageID: assistant.id,
                    metadata: structuredMetadata,
                    committedAt: Date(timeIntervalSince1970: 4)
                ))
            ),
            AgentHistoryRecord(
                sequenceNumber: 6,
                createdAt: Date(timeIntervalSince1970: 5),
                item: .toolCall(AgentToolCallRecord(invocation: orphanedInvocation))
            ),
        ]
        let store = try SQLiteRuntimeStateStore(url: url)
        try await store.saveState(StoredRuntimeState(
            threads: [thread],
            historyByThread: [thread.id: records]
        ))

        let activation = try await store.loadThreadActivationState(
            id: thread.id,
            policy: .init(
                maximumMessageCount: 4,
                maximumEstimatedTokens: 200,
                maximumHistoryRecordCount: 16
            )
        )
        let texts = activation.effectiveMessages.map(\.text)
        XCTAssertTrue(texts.contains { $0.contains("lookup") && $0.contains("ready") })
        XCTAssertFalse(texts.contains { $0.contains("must_not_appear") })
        let interaction = try XCTUnwrap(
            activation.effectiveMessages.first(where: { $0.role == .tool })?.toolInteraction
        )
        XCTAssertEqual(interaction.invocation, pairedInvocation)
        XCTAssertEqual(interaction.result.invocationID, pairedInvocation.id)
        XCTAssertEqual(interaction.result.primaryText, "ready")
        XCTAssertEqual(
            activation.effectiveMessages.last?.structuredOutput,
            structuredMetadata
        )

        try await store.apply([
            .upsertThreadContextState(
                threadID: thread.id,
                state: AgentThreadContextState(
                    threadID: thread.id,
                    effectiveMessages: activation.effectiveMessages
                )
            ),
        ])
        let reopenedStore = try SQLiteRuntimeStateStore(url: url)
        let reopenedActivation = try await reopenedStore.loadThreadActivationState(
            id: thread.id,
            policy: .init(
                maximumMessageCount: 4,
                maximumEstimatedTokens: 200,
                maximumHistoryRecordCount: 16
            )
        )
        XCTAssertEqual(
            reopenedActivation.effectiveMessages.first(where: { $0.role == .tool })?.toolInteraction,
            interaction
        )
    }

    func testSQLiteActivationHonorsLatestCompactionMarkerBoundary() async throws {
        let url = temporaryRuntimeSQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let thread = AgentThread(id: "compacted-activation")
        let marker = AgentContextCompactionMarker(
            generation: 1,
            reason: .manual,
            effectiveMessageCountBefore: 2,
            effectiveMessageCountAfter: 1,
            debugSummaryPreview: "The earlier discussion was compacted safely."
        )
        let records = [
            AgentHistoryRecord(
                sequenceNumber: 1,
                createdAt: Date(timeIntervalSince1970: 1),
                item: .message(AgentMessage(
                    threadID: thread.id,
                    role: .user,
                    text: "old question"
                ))
            ),
            AgentHistoryRecord(
                sequenceNumber: 2,
                createdAt: Date(timeIntervalSince1970: 2),
                item: .message(AgentMessage(
                    threadID: thread.id,
                    role: .assistant,
                    text: "old answer"
                ))
            ),
            AgentHistoryRecord(
                sequenceNumber: 3,
                createdAt: Date(timeIntervalSince1970: 3),
                item: .systemEvent(AgentSystemEventRecord(
                    type: .contextCompacted,
                    threadID: thread.id,
                    compaction: marker
                ))
            ),
            AgentHistoryRecord(
                sequenceNumber: 4,
                createdAt: Date(timeIntervalSince1970: 4),
                item: .message(AgentMessage(
                    threadID: thread.id,
                    role: .user,
                    text: "recent question"
                ))
            ),
            AgentHistoryRecord(
                sequenceNumber: 5,
                createdAt: Date(timeIntervalSince1970: 5),
                item: .message(AgentMessage(
                    threadID: thread.id,
                    role: .assistant,
                    text: "recent answer"
                ))
            ),
        ]
        let store = try SQLiteRuntimeStateStore(url: url)
        try await store.saveState(StoredRuntimeState(
            threads: [thread],
            historyByThread: [thread.id: records]
        ))

        let activation = try await store.loadThreadActivationState(
            id: thread.id,
            policy: .init(
                maximumMessageCount: 4,
                maximumEstimatedTokens: 200,
                maximumHistoryRecordCount: 16
            )
        )
        let texts = activation.effectiveMessages.map(\.text)
        XCTAssertFalse(texts.contains("old question"))
        XCTAssertFalse(texts.contains("old answer"))
        XCTAssertTrue(texts.contains { $0.contains("earlier discussion was compacted") })
        XCTAssertEqual(Array(texts.suffix(2)), ["recent question", "recent answer"])
    }

    func testDeactivateAndColdReactivateReleaseWorkingSetWithoutChangingHistory() async throws {
        let url = temporaryRuntimeSQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let backend = InMemoryAgentBackend()
        let store = try SQLiteRuntimeStateStore(url: url)
        let runtime = try makeHistoryRuntime(
            backend: backend,
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: store
        )
        _ = try await runtime.restore()
        _ = try await runtime.useSession(demoSession())
        let thread = try await runtime.createThread()
        _ = try await runtime.send(Request(text: "remember this"), in: thread.id)
        let historyBefore = try await runtime.execute(HistoryItemsQuery(threadID: thread.id))

        await runtime.deactivateThread(id: thread.id)
        let inactiveCount = await runtime.activeThreadCount()
        let inactiveMessages = await runtime.messages(for: thread.id)
        XCTAssertEqual(inactiveCount, 0)
        XCTAssertTrue(inactiveMessages.isEmpty)

        _ = try await runtime.resumeThread(id: thread.id)
        let reactivatedCount = await runtime.activeThreadCount()
        let reactivatedMessages = await runtime.messages(for: thread.id)
        XCTAssertEqual(reactivatedCount, 1)
        XCTAssertTrue(reactivatedMessages.contains { $0.text == "remember this" })
        let historyAfter = try await runtime.execute(HistoryItemsQuery(threadID: thread.id))
        XCTAssertEqual(historyAfter.records.count, historyBefore.records.count + 1)
    }

    func testRepeatedActivationDeactivationReturnsWorkingSetToBaseline() async throws {
        let url = temporaryRuntimeSQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let threads = (0 ..< 16).map { AgentThread(id: "lifecycle-\($0)") }
        let histories = Dictionary(uniqueKeysWithValues: threads.map { thread in
            (
                thread.id,
                [
                    AgentHistoryRecord(
                        sequenceNumber: 1,
                        createdAt: Date(timeIntervalSince1970: 1),
                        item: .message(AgentMessage(
                            threadID: thread.id,
                            role: .user,
                            text: "question for \(thread.id)"
                        ))
                    ),
                    AgentHistoryRecord(
                        sequenceNumber: 2,
                        createdAt: Date(timeIntervalSince1970: 2),
                        item: .message(AgentMessage(
                            threadID: thread.id,
                            role: .assistant,
                            text: "answer for \(thread.id)"
                        ))
                    ),
                ]
            )
        })
        let store = try SQLiteRuntimeStateStore(url: url)
        try await store.saveState(StoredRuntimeState(
            threads: threads,
            historyByThread: histories
        ))
        let runtime = try makeHistoryRuntime(
            backend: InMemoryAgentBackend(),
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: store
        )
        _ = try await runtime.restore()
        _ = try await runtime.useSession(demoSession())

        for thread in threads {
            _ = try await runtime.resumeThread(id: thread.id)
            let activeCount = await runtime.activeThreadCount()
            let activeMessages = await runtime.messages(for: thread.id)
            XCTAssertEqual(activeCount, 1)
            XCTAssertEqual(
                activeMessages.map(\.text),
                ["question for \(thread.id)", "answer for \(thread.id)"]
            )
            await runtime.deactivateThread(id: thread.id)
            let inactiveCount = await runtime.activeThreadCount()
            XCTAssertEqual(inactiveCount, 0)
        }

        for thread in threads {
            let history = try await store.execute(HistoryItemsQuery(threadID: thread.id))
            XCTAssertEqual(history.records.map(\.sequenceNumber), [1, 2, 3])
        }
    }

    func testResumeMissingLocalThreadDoesNotCreateReplacement() async throws {
        let url = temporaryRuntimeSQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let runtime = try makeHistoryRuntime(
            backend: InMemoryAgentBackend(),
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: try SQLiteRuntimeStateStore(url: url)
        )
        _ = try await runtime.restore()
        _ = try await runtime.useSession(demoSession())

        do {
            _ = try await runtime.resumeThread(id: "missing")
            XCTFail("Expected a missing local thread to be rejected.")
        } catch let error as AgentRuntimeError {
            XCTAssertEqual(error.code, "thread_not_found")
        }

        let threads = try await runtime.execute(
            ThreadMetadataQuery(threadIDs: ["missing"])
        )
        XCTAssertTrue(threads.isEmpty)
    }

    func testConcurrentSQLiteThreadsKeepIndependentMonotonicSequences() async throws {
        let url = temporaryRuntimeSQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let runtime = try makeHistoryRuntime(
            backend: InMemoryAgentBackend(),
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: try SQLiteRuntimeStateStore(url: url)
        )
        _ = try await runtime.restore()
        _ = try await runtime.useSession(demoSession())
        var threads: [AgentThread] = []
        for title in ["One", "Two", "Three"] {
            threads.append(try await runtime.createThread(title: title))
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, thread) in threads.enumerated() {
                group.addTask {
                    _ = try await runtime.send(
                        Request(text: "concurrent \(index)"),
                        in: thread.id
                    )
                }
            }
            try await group.waitForAll()
        }

        for thread in threads {
            let history = try await runtime.execute(HistoryItemsQuery(threadID: thread.id))
            XCTAssertEqual(
                history.records.map(\.sequenceNumber),
                Array(1 ... history.records.count)
            )
            XCTAssertTrue(history.records.allSatisfy { record in
                switch record.item {
                case let .message(message):
                    return message.threadID == thread.id
                case let .toolCall(toolCall):
                    return toolCall.invocation.threadID == thread.id
                case let .toolResult(toolResult):
                    return toolResult.threadID == thread.id
                case let .structuredOutput(output):
                    return output.threadID == thread.id
                case let .approval(approval):
                    return approval.request?.threadID == thread.id
                        || approval.resolution?.threadID == thread.id
                case let .systemEvent(event):
                    return event.threadID == thread.id
                }
            })
        }
    }

    func testConcurrentPersistencePublishesEachCommittedSnapshotInOrder() async throws {
        let store = BlockingRuntimeStateStore(base: InMemoryRuntimeStateStore())
        let runtime = try makeHistoryRuntime(
            backend: InMemoryAgentBackend(),
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: store
        )
        _ = try await runtime.restore()
        _ = try await runtime.useSession(demoSession())
        let thread = try await runtime.createThread(title: "Initial")
        let recorder = ThreadTitleObservationRecorder(threadID: thread.id)
        let cancellable = await runtime.observations.sink { observation in
            recorder.record(observation)
        }
        defer { cancellable.cancel() }

        await store.blockNextApply()
        let firstUpdate = Task {
            try await runtime.setTitle("First committed", for: thread.id)
        }
        await store.waitForBlockedApply()

        let secondUpdate = Task {
            try await runtime.setTitle("Second committed", for: thread.id)
        }
        try await waitUntil {
            await runtime.activeThreads().first(where: { $0.id == thread.id })?.title
                == "Second committed"
        }
        await store.releaseBlockedApply()
        try await firstUpdate.value
        try await secondUpdate.value
        try await waitUntil {
            recorder.titles().count == 2
        }

        XCTAssertEqual(recorder.titles(), ["First committed", "Second committed"])
    }

    func testFailedWriteCannotRecoverOverANewerSameThreadMutation() async throws {
        let store = BlockingRuntimeStateStore(base: InMemoryRuntimeStateStore())
        let runtime = try makeHistoryRuntime(
            backend: InMemoryAgentBackend(),
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: store
        )
        _ = try await runtime.restore()
        _ = try await runtime.useSession(demoSession())
        let thread = try await runtime.createThread(title: "Initial")

        await store.blockAndFailNextApply()
        let firstUpdate = Task {
            try await runtime.setTitle("First must fail", for: thread.id)
        }
        await store.waitForBlockedApply()
        let secondUpdate = Task {
            try await runtime.setTitle("Second must win", for: thread.id)
        }
        try await waitUntil {
            await runtime.activeThreads().first(where: { $0.id == thread.id })?.title
                == "Second must win"
        }
        await store.releaseBlockedApply()

        await XCTAssertThrowsErrorAsync(try await firstUpdate.value)
        try await secondUpdate.value
        let activeTitle = await runtime.activeThreads()
            .first(where: { $0.id == thread.id })?.title
        let persistedState = try await store.loadState()
        let persistedTitle = persistedState.threads
            .first(where: { $0.id == thread.id })?.title
        XCTAssertEqual(activeTitle, "Second must win")
        XCTAssertEqual(persistedTitle, "Second must win")
    }

    func testMiddleThreadFailureDoesNotDropLaterThreadGroups() async throws {
        let base = InMemoryRuntimeStateStore()
        let threads = ["blocker", "first", "middle", "last"].map {
            AgentThread(id: $0, title: "Initial \($0)")
        }
        try await base.saveState(StoredRuntimeState(threads: threads))
        let store = BlockingRuntimeStateStore(base: base)
        let runtime = try makeHistoryRuntime(
            backend: InMemoryAgentBackend(),
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: store
        )
        _ = try await runtime.restore()

        await store.blockNextApply()
        let blocker = Task {
            try await runtime.setTitle("Blocker committed", for: "blocker")
        }
        await store.waitForBlockedApply()
        await store.failNextApply(for: "middle")

        let first = Task { try await runtime.setTitle("First committed", for: "first") }
        try await waitUntil {
            await runtime.activeThreads().first(where: { $0.id == "first" })?.title
                == "First committed"
        }
        let middle = Task { try await runtime.setTitle("Middle failed", for: "middle") }
        try await waitUntil {
            await runtime.activeThreads().first(where: { $0.id == "middle" })?.title
                == "Middle failed"
        }
        let last = Task { try await runtime.setTitle("Last committed", for: "last") }
        try await waitUntil {
            await runtime.activeThreads().first(where: { $0.id == "last" })?.title
                == "Last committed"
        }
        await store.releaseBlockedApply()

        try await blocker.value
        _ = try? await first.value
        _ = try? await middle.value
        _ = try? await last.value

        let persisted = try await store.loadState()
        XCTAssertEqual(persisted.threads.first(where: { $0.id == "first" })?.title, "First committed")
        XCTAssertEqual(persisted.threads.first(where: { $0.id == "middle" })?.title, "Initial middle")
        XCTAssertEqual(persisted.threads.first(where: { $0.id == "last" })?.title, "Last committed")
    }

    func testConcurrentRuntimesRetrySameThreadSequenceAllocation() async throws {
        let url = temporaryRuntimeSQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let thread = AgentThread(id: "shared-runtime-thread")
        let seedStore = try SQLiteRuntimeStateStore(url: url)
        try await seedStore.saveState(StoredRuntimeState(threads: [thread]))

        let backend = ConcurrentResumeBarrierBackend()
        let firstRuntime = try makeHistoryRuntime(
            backend: backend,
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: try SQLiteRuntimeStateStore(url: url)
        )
        let secondRuntime = try makeHistoryRuntime(
            backend: backend,
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: try SQLiteRuntimeStateStore(url: url)
        )
        _ = try await firstRuntime.restore()
        _ = try await secondRuntime.restore()
        _ = try await firstRuntime.useSession(demoSession())
        _ = try await secondRuntime.useSession(demoSession())

        async let firstResume = firstRuntime.resumeThread(id: thread.id)
        async let secondResume = secondRuntime.resumeThread(id: thread.id)
        let resumed = try await [firstResume, secondResume]
        XCTAssertEqual(Set(resumed.map(\.id)), [thread.id])

        let history = try await seedStore.execute(HistoryItemsQuery(threadID: thread.id))
        XCTAssertEqual(history.records.map(\.sequenceNumber), [1, 2])
        XCTAssertTrue(history.records.allSatisfy { record in
            guard case let .systemEvent(event) = record.item else { return false }
            return event.type == .threadResumed
        })
    }
}

private enum InjectedRuntimeStoreError: Error, Equatable {
    case appendFailed
}

private actor FailOnceRuntimeStateStore: RuntimeStateStoring, AgentRuntimeQueryableStore {
    private let base: SQLiteRuntimeStateStore
    private var shouldFailHistoryAppend = false

    init(base: SQLiteRuntimeStateStore) {
        self.base = base
    }

    func failNextHistoryAppend() {
        shouldFailHistoryAppend = true
    }

    func prepare() async throws -> AgentStoreMetadata {
        try await base.prepare()
    }

    func readMetadata() async throws -> AgentStoreMetadata {
        try await base.readMetadata()
    }

    func loadState() async throws -> StoredRuntimeState {
        try await base.loadState()
    }

    func saveState(_ state: StoredRuntimeState) async throws {
        try await base.saveState(state)
    }

    func loadThreadActivationState(
        id: String,
        policy: AgentThreadActivationPolicy
    ) async throws -> AgentThreadActivationState {
        try await base.loadThreadActivationState(id: id, policy: policy)
    }

    func apply(_ operations: [AgentStoreWriteOperation]) async throws {
        if shouldFailHistoryAppend,
           operations.contains(where: { operation in
               if case .appendHistoryItems = operation { return true }
               if case .appendCompactionMarker = operation { return true }
               return false
           }) {
            shouldFailHistoryAppend = false
            throw InjectedRuntimeStoreError.appendFailed
        }
        try await base.apply(operations)
    }

    func execute<Query: AgentQuerySpec>(_ query: Query) async throws -> Query.Result {
        try await base.execute(query)
    }
}

private actor BlockingRuntimeStateStore: RuntimeStateStoring {
    private let base: InMemoryRuntimeStateStore
    private var shouldBlockNextApply = false
    private var blockedApplyStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var blockedApplyReleased = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var shouldFailBlockedApply = false
    private var threadIDToFail: String?

    init(base: InMemoryRuntimeStateStore) {
        self.base = base
    }

    func blockNextApply() {
        shouldBlockNextApply = true
        blockedApplyStarted = false
        blockedApplyReleased = false
        shouldFailBlockedApply = false
    }

    func blockAndFailNextApply() {
        blockNextApply()
        shouldFailBlockedApply = true
    }

    func failNextApply(for threadID: String) {
        threadIDToFail = threadID
    }

    func waitForBlockedApply() async {
        guard !blockedApplyStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseBlockedApply() {
        blockedApplyReleased = true
        let continuations = releaseWaiters
        releaseWaiters.removeAll()
        continuations.forEach { $0.resume() }
    }

    func prepare() async throws -> AgentStoreMetadata {
        try await base.prepare()
    }

    func readMetadata() async throws -> AgentStoreMetadata {
        try await base.readMetadata()
    }

    func loadState() async throws -> StoredRuntimeState {
        try await base.loadState()
    }

    func saveState(_ state: StoredRuntimeState) async throws {
        try await base.saveState(state)
    }

    func loadThreadActivationState(
        id: String,
        policy: AgentThreadActivationPolicy
    ) async throws -> AgentThreadActivationState {
        try await base.loadThreadActivationState(id: id, policy: policy)
    }

    func apply(_ operations: [AgentStoreWriteOperation]) async throws {
        var mustFailAfterBlock = false
        if shouldBlockNextApply {
            shouldBlockNextApply = false
            mustFailAfterBlock = shouldFailBlockedApply
            shouldFailBlockedApply = false
            blockedApplyStarted = true
            let continuations = startWaiters
            startWaiters.removeAll()
            continuations.forEach { $0.resume() }
            if !blockedApplyReleased {
                await withCheckedContinuation { continuation in
                    releaseWaiters.append(continuation)
                }
            }
        }
        if mustFailAfterBlock {
            throw InjectedRuntimeStoreError.appendFailed
        }
        if let threadIDToFail,
           operations.contains(where: { $0.affectedThreadID == threadIDToFail }) {
            self.threadIDToFail = nil
            throw InjectedRuntimeStoreError.appendFailed
        }
        try await base.apply(operations)
    }
}

private final class ThreadTitleObservationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let threadID: String
    private var recordedTitles: [String] = []

    init(threadID: String) {
        self.threadID = threadID
    }

    func record(_ observation: AgentRuntimeObservation) {
        guard case let .threadChanged(thread) = observation,
              thread.id == threadID,
              let title = thread.title
        else {
            return
        }
        lock.lock()
        recordedTitles.append(title)
        lock.unlock()
    }

    func titles() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedTitles
    }
}

private actor ConcurrentResumeBarrierBackend: AgentBackend {
    private var resumeArrivalCount = 0
    private var resumeWaiters: [CheckedContinuation<Void, Never>] = []

    func createThread(session _: ChatGPTSession) async throws -> AgentThread {
        AgentThread(id: UUID().uuidString)
    }

    func resumeThread(id: String, session _: ChatGPTSession) async throws -> AgentThread {
        resumeArrivalCount += 1
        if resumeArrivalCount < 2 {
            await withCheckedContinuation { continuation in
                resumeWaiters.append(continuation)
            }
        } else {
            let continuations = resumeWaiters
            resumeWaiters.removeAll()
            continuations.forEach { $0.resume() }
        }
        return AgentThread(id: id)
    }

    func beginTurn(
        thread: AgentThread,
        history _: [AgentMessage],
        message: Request,
        instructions _: String,
        responseFormat _: AgentStructuredOutputFormat?,
        streamedStructuredOutput _: AgentStreamedStructuredOutputRequest?,
        tools _: [ToolDefinition],
        session _: ChatGPTSession
    ) async throws -> AgentTurnStream {
        MockAgentTurnSession(
            thread: thread,
            message: message,
            selectedTool: nil,
            structuredResponseText: nil,
            streamedStructuredOutput: nil
        ).stream
    }
}
