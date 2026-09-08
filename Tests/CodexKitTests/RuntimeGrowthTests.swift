@testable import CodexKit
import CodexKitSQLite
import CodexKitRealm
import XCTest

final class RuntimeGrowthTests: XCTestCase {
    func testEvictedToolResultsAreNotExecutedAgainAfterRuntimeReload() async throws {
        for (adapter, historyLimit) in [("sqlite", 0), ("sqlite", 1), ("realm", 0), ("realm", 1)] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store: any RuntimeStateStoring = adapter == "sqlite"
                ? try SQLiteRuntimeStateStore(url: directory.appendingPathComponent("sqlite.sqlite"))
                : try RealmRuntimeStateStore(url: directory.appendingPathComponent("realm.realm"))
            let secure = KeychainSessionSecureStore(service: "CodexKit.GrowthTests", account: UUID().uuidString)
            defer { try? secure.deleteSession() }
            let executions = GrowthExecutionCounter()
            let configuration = AgentRuntime.Configuration(authProvider: DemoChatGPTAuthProvider(), secureStore: secure,
                backend: GrowthReplayBackend(), approvalPresenter: AutoApprovalPresenter(), stateStore: store,
                tools: [.init(definition: .init(name: "lookup", description: "lookup", inputSchema: .object([:])),
                    executor: AnyToolExecutor { invocation, _ in
                        await executions.record()
                        return .success(invocation: invocation, text: "Saved result")
                    })], threadActivationPolicy: .init(maximumMessageCount: 2, maximumHistoryRecordCount: historyLimit))
            let first = try AgentRuntime(configuration: configuration)
            _ = try await first.useSession(demoSession())
            let thread = try await first.createThread()
            for _ in 0..<3 {
                let reply = try await first.send(Request(text: "Use lookup"), in: thread.id)
                XCTAssertEqual(reply, "Saved result")
                let retained = await first.state.historyByThread[thread.id]?.count
                XCTAssertLessThanOrEqual(retained ?? 0, historyLimit)
            }
            let second = try AgentRuntime(configuration: configuration)
            _ = try await second.restore()
            _ = try await second.resumeThread(id: thread.id)
            _ = try await second.send(Request(text: "Replay lookup"), in: thread.id)
            let count = await executions.count
            XCTAssertEqual(count, 1, adapter)
            let records = try await second.execute(HistoryItemsQuery(threadID: thread.id,
                kinds: [.toolResult], relationship: .toolInvocation(id: "stable-call")))
            XCTAssertEqual(records.records.count, 1)
            let summary = try await second.fetchThreadSummary(id: thread.id)
            XCTAssertGreaterThan(summary.itemCount ?? 0, 1, "Eviction must not delete durable history")
        }
    }

    func testRelationshipQueriesUseTheSameSemanticsAcrossStores() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stores: [any RuntimeStateStoring] = [InMemoryRuntimeStateStore(),
            FileRuntimeStateStore(url: directory.appendingPathComponent("file.json")),
            try SQLiteRuntimeStateStore(url: directory.appendingPathComponent("sqlite.sqlite")),
            try RealmRuntimeStateStore(url: directory.appendingPathComponent("realm.realm"))]
        let thread = AgentThread(id: "thread")
        let invocation = ToolInvocation(id: "call:with:colons", threadID: thread.id, turnID: "turn", toolName: "lookup", arguments: .null)
        let items: [AgentHistoryItem] = [
            .message(.init(id: "message", threadID: thread.id, role: .assistant, text: "Hello")),
            .toolCall(.init(invocation: invocation, requestedAt: Date())),
            .toolResult(.init(threadID: thread.id, turnID: "turn", result: .success(invocation: invocation, text: "Result"), completedAt: Date()))]
        for store in stores {
            _ = try await store.prepare()
            try await store.apply([.upsertThread(thread), .appendHistoryItems(threadID: thread.id,
                items: items.enumerated().map { .init(sequenceNumber: $0.offset + 1, createdAt: Date(), item: $0.element) })])
            let runtime = try AgentRuntime(configuration: .init(authProvider: DemoChatGPTAuthProvider(),
                secureStore: KeychainSessionSecureStore(service: "CodexKit.Unused", account: UUID().uuidString),
                backend: GrowthReplayBackend(), approvalPresenter: AutoApprovalPresenter(), stateStore: store))
            let pair = try await runtime.execute(HistoryItemsQuery(threadID: thread.id, relationship: .toolInvocation(id: invocation.id)))
            XCTAssertEqual(pair.records.map(\.item.kind), [.toolCall, .toolResult])
            let message = try await runtime.execute(HistoryItemsQuery(threadID: thread.id, relationship: .message(id: "message")))
            XCTAssertEqual(message.records.count, 1)
            let absent = try await runtime.execute(HistoryItemsQuery(threadID: thread.id, relationship: .toolInvocation(id: "missing")))
            XCTAssertTrue(absent.records.isEmpty)
        }
    }
}

private actor GrowthExecutionCounter {
    var count = 0
    func record() { count += 1 }
}

private struct GrowthReplayBackend: AgentBackend {
    func createThread(session: ChatGPTSession) async throws -> AgentThread { AgentThread(id: "growth-thread") }
    func resumeThread(id: String, session: ChatGPTSession) async throws -> AgentThread { AgentThread(id: id) }
    func beginTurn(thread: AgentThread, history: [AgentMessage], message: Request, instructions: String,
        responseFormat: AgentStructuredOutputFormat?, streamedStructuredOutput: AgentStreamedStructuredOutputRequest?,
        tools: [ToolDefinition], session: ChatGPTSession) async throws -> AgentTurnStream {
        let pending = PendingToolResults()
        let events = AsyncThrowingStream<AgentBackendEvent, Error> { continuation in
            let task = Task {
                do {
                    continuation.yield(.turnStarted(.init(id: "stable-turn", threadID: thread.id)))
                    continuation.yield(.toolCallRequested(.init(id: "stable-call", threadID: thread.id,
                        turnID: "stable-turn", toolName: "lookup", arguments: .null)))
                    let result = try await pending.wait(for: "stable-call")
                    continuation.yield(.assistantMessageCompleted(.init(threadID: thread.id, role: .assistant, text: result.primaryText ?? "")))
                    continuation.yield(.turnCompleted(.init(threadID: thread.id, turnID: "stable-turn")))
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { if case .cancelled = $0 { task.cancel() } }
        }
        return AgentTurnStream(events: events) { result, id in await pending.resolve(result, for: id) }
    }
}
