import CodexKit
import CodexKitUI
import XCTest

extension AgentRuntimeTests {
    func testManualCompactionPreservesVisibleHistoryAndHidesMarkersByDefault() async throws {
        let backend = CompactingTestBackend()
        let runtime = try makeHistoryRuntime(backend: backend, approvalPresenter: AutoApprovalPresenter(), stateStore: InMemoryRuntimeStateStore(), contextCompaction: AgentContextCompactionConfiguration(isEnabled: true, mode: .automatic))
        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread(title: "Compaction")
        let longMessages = [
            String(repeating: "first message context ", count: 30),
            String(repeating: "second message context ", count: 30),
            String(repeating: "third message context ", count: 30),
        ]
        for message in longMessages {
            _ = try await runtime.send(Request(text: message), in: thread.id)
        }

        let visibleBefore = await runtime.messages(for: thread.id)
        XCTAssertEqual(visibleBefore.count, 6)

        let contextState = try await runtime.compactThreadContext(id: thread.id)
        let visibleAfter = await runtime.messages(for: thread.id)
        let defaultSystemHistory = try await runtime.execute(
            HistoryItemsQuery(threadID: thread.id, kinds: [.systemEvent])
        )
        let debugSystemHistory = try await runtime.execute(
            HistoryItemsQuery(
                threadID: thread.id,
                kinds: [.systemEvent],
                includeCompactionEvents: true
            )
        )

        XCTAssertEqual(contextState.generation, 1)
        XCTAssertLessThan(contextState.effectiveMessages.count, visibleBefore.count)
        XCTAssertEqual(visibleAfter, visibleBefore)
        XCTAssertFalse(defaultSystemHistory.records.contains { $0.item.isCompactionMarker })
        XCTAssertTrue(debugSystemHistory.records.contains { $0.item.isCompactionMarker })
    }

    func testAutomaticRetryCompactionRecoversFromContextLimitError() async throws {
        let backend = CompactingTestBackend(failOnHistoryCountAbove: 2)
        let runtime = try makeHistoryRuntime(
            backend: backend,
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: InMemoryRuntimeStateStore(),
            contextCompaction: AgentContextCompactionConfiguration(isEnabled: true, mode: .automatic, trigger: AgentContextCompactionTrigger(estimatedTokenThreshold: 100_000, retryOnContextLimitError: true))
        )
        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread(title: "Retry Compact")
        _ = try await runtime.send(Request(text: "one"), in: thread.id)
        _ = try await runtime.send(Request(text: "two"), in: thread.id)
        _ = try await runtime.send(Request(text: "three"), in: thread.id)
        let reply = try await runtime.send(Request(text: "four"), in: thread.id)
        let compactCallCount = await backend.compactCallCount()
        let historyCounts = await backend.beginTurnHistoryCounts()

        XCTAssertEqual(reply, "Echo: four")
        XCTAssertEqual(compactCallCount, 1)
        XCTAssertGreaterThanOrEqual(historyCounts.count, 5)
    }

    func testContextStatePersistsAcrossGRDBReload() async throws {
        let url = temporaryRuntimeSQLiteURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let backend = CompactingTestBackend()
        let runtime = try makeHistoryRuntime(backend: backend, approvalPresenter: AutoApprovalPresenter(), stateStore: try SQLiteRuntimeStateStore(url: url), contextCompaction: AgentContextCompactionConfiguration(isEnabled: true, mode: .automatic))
        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread(title: "Persisted Context")
        _ = try await runtime.send(Request(text: "alpha"), in: thread.id)
        _ = try await runtime.send(Request(text: "beta"), in: thread.id)
        _ = try await runtime.compactThreadContext(id: thread.id)

        let reloadedRuntime = try makeHistoryRuntime(backend: backend, approvalPresenter: AutoApprovalPresenter(), stateStore: try SQLiteRuntimeStateStore(url: url), contextCompaction: AgentContextCompactionConfiguration(isEnabled: true, mode: .automatic))
        let restoredContext = try await reloadedRuntime.fetchThreadContextState(id: thread.id)
        XCTAssertEqual(restoredContext?.generation, 1)
        XCTAssertFalse(restoredContext?.effectiveMessages.isEmpty ?? true)
    }

    func testFetchThreadContextUsageReportsVisibleAndEffectiveTokenCounts() async throws {
        let backend = CompactingTestBackend()
        let runtime = try makeHistoryRuntime(
            backend: backend,
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: InMemoryRuntimeStateStore(),
            contextCompaction: .init(
                isEnabled: true,
                mode: .manual,
                strategy: .preferRemoteThenLocal
            )
        )
        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread(title: "Usage")
        let longMessages = [
            String(repeating: "first message context ", count: 30),
            String(repeating: "second message context ", count: 30),
            String(repeating: "third message context ", count: 30),
        ]
        for message in longMessages {
            _ = try await runtime.send(Request(text: message), in: thread.id)
        }

        let usageBefore = try await runtime.fetchThreadContextUsage(id: thread.id)
        let unwrappedUsageBefore = try XCTUnwrap(usageBefore)
        XCTAssertEqual(
            unwrappedUsageBefore.visibleEstimatedTokenCount,
            unwrappedUsageBefore.effectiveEstimatedTokenCount
        )
        XCTAssertEqual(unwrappedUsageBefore.modelContextWindowTokenCount, 272_000)
        XCTAssertEqual(unwrappedUsageBefore.usableContextWindowTokenCount, 258_400)
        XCTAssertNotNil(unwrappedUsageBefore.percentUsed)

        _ = try await runtime.compactThreadContext(id: thread.id)

        let usageAfter = try await runtime.fetchThreadContextUsage(id: thread.id)
        let unwrappedUsageAfter = try XCTUnwrap(usageAfter)
        XCTAssertEqual(
            unwrappedUsageAfter.visibleEstimatedTokenCount,
            unwrappedUsageBefore.visibleEstimatedTokenCount
        )
        XCTAssertLessThan(
            unwrappedUsageAfter.effectiveEstimatedTokenCount,
            unwrappedUsageBefore.effectiveEstimatedTokenCount
        )
        XCTAssertGreaterThan(unwrappedUsageAfter.estimatedTokenSavings, 0)
    }

    func testContextCompactionConfigurationDefaultsAndCodableShape() throws {
        let configuration = AgentContextCompactionConfiguration()
        XCTAssertFalse(configuration.isEnabled)
        XCTAssertEqual(configuration.mode, .automatic)

        let encoded = try JSONEncoder().encode(AgentContextCompactionConfiguration(isEnabled: true, mode: .manual))
        let decoded = try JSONDecoder().decode(AgentContextCompactionConfiguration.self, from: encoded)
        XCTAssertTrue(decoded.isEnabled)
        XCTAssertEqual(decoded.mode, .manual)
    }
}
