@testable import CodexKit
import CodexKitUI
import XCTest

final class AgentTurnLimitsTests: XCTestCase {
    override func setUp() async throws { await TestURLProtocol.reset() }
    override func tearDown() async throws { await TestURLProtocol.reset() }

    func testToolBudgetRejectsWholeBatchBeforeAnyExecutorRuns() async throws {
        for structured in [false, true] {
            let secure = secureStore()
            defer { try? secure.deleteSession() }
            let counter = LimitCallCounter()
            let runtime = try AgentRuntime(configuration: .init(authProvider: DemoChatGPTAuthProvider(),
                secureStore: secure, backend: LimitBatchBackend(), approvalPresenter: AutoApprovalPresenter(),
                stateStore: InMemoryRuntimeStateStore(), maximumBufferedEvents: 1,
                turnLimits: .init(maximumToolCalls: 1), tools: [.init(
                    definition: .init(name: "lookup", description: "lookup", inputSchema: .object([:]), supportsParallelExecution: true),
                    executor: .init { invocation, _ in
                        await counter.record()
                        return .success(invocation: invocation, text: "Done")
                    })]))
            _ = try await runtime.useSession(demoSession())
            let thread = try await runtime.createThread()
            var sawFailure = false
            do {
                if structured {
                    for try await event in try await runtime.stream(Request(text: "Go"), in: thread.id, response: LimitOutput.self) {
                        if case let .turnFailed(error) = event { sawFailure = error.executionLimit == .toolCalls }
                    }
                } else {
                    for try await event in try await runtime.stream(Request(text: "Go"), in: thread.id) {
                        if case let .turnFailed(error) = event { sawFailure = error.executionLimit == .toolCalls }
                    }
                }
                XCTFail("Expected the tool-call budget to fail")
            } catch { XCTAssertEqual((error as? AgentRuntimeError)?.executionLimit, .toolCalls) }
            XCTAssertTrue(sawFailure)
            let calls = await counter.count
            XCTAssertEqual(calls, 0)
            let summary = try await runtime.fetchThreadSummary(id: thread.id)
            XCTAssertEqual(summary.latestTurnStatus, .failed)
            XCTAssertNil(summary.pendingState)
            let active = await runtime.activeTurnID(in: thread.id)
            XCTAssertNil(active)
        }
    }

    func testTimeoutPreservesFailureEventsWhenConsumerPausesWithAFullQueue() async throws {
        let secure = secureStore()
        defer { try? secure.deleteSession() }
        let runtime = try AgentRuntime(configuration: .init(authProvider: DemoChatGPTAuthProvider(), secureStore: secure,
            backend: LimitBatchBackend(), approvalPresenter: AutoApprovalPresenter(), stateStore: InMemoryRuntimeStateStore(),
            maximumBufferedEvents: 1, turnLimits: .init(maximumDuration: 0.05)))
        _ = try await runtime.useSession(demoSession())
        let thread = try await runtime.createThread()
        let stream = try await runtime.stream(Request(text: "Go"), in: thread.id)
        try await Task.sleep(for: .milliseconds(150))
        var sawFailure = false
        var sawFailedStatus = false
        do {
            for try await event in stream {
                if case let .turnFailed(error) = event { sawFailure = error.executionLimit == .duration }
                if case let .threadStatusChanged(_, status) = event { sawFailedStatus = status == .failed }
            }
            XCTFail("Expected the duration budget to fail")
        } catch { XCTAssertEqual((error as? AgentRuntimeError)?.executionLimit, .duration) }
        XCTAssertTrue(sawFailure)
        XCTAssertTrue(sawFailedStatus)
        let active = await runtime.activeTurnID(in: thread.id)
        XCTAssertNil(active)
    }

    @MainActor
    func testTimeoutDuringApprovalClearsInboxAndPersistsFailedStatus() async throws {
        let secure = secureStore()
        defer { try? secure.deleteSession() }
        let inbox = ApprovalInbox()
        let counter = LimitCallCounter()
        let runtime = try AgentRuntime(configuration: .init(authProvider: DemoChatGPTAuthProvider(), secureStore: secure,
            backend: LimitBatchBackend(), approvalPresenter: inbox, stateStore: InMemoryRuntimeStateStore(),
            maximumBufferedEvents: 1, turnLimits: .init(maximumDuration: 0.3), tools: [.init(
                definition: .init(name: "lookup", description: "lookup", inputSchema: .object([:]), approvalPolicy: .requiresApproval),
                executor: .init { invocation, _ in
                    await counter.record()
                    return .success(invocation: invocation, text: "Done")
                })]))
        _ = try await runtime.useSession(demoSession())
        let thread = try await runtime.createThread()
        var sawApproval = false
        do {
            for try await event in try await runtime.stream(Request(text: "Go"), in: thread.id) {
                if case .approvalRequested = event { sawApproval = true }
            }
            XCTFail("Expected approval wait to time out")
        } catch { XCTAssertEqual((error as? AgentRuntimeError)?.executionLimit, .duration) }
        XCTAssertTrue(sawApproval)
        XCTAssertNil(inbox.currentRequest)
        let summary = try await runtime.fetchThreadSummary(id: thread.id)
        XCTAssertEqual(summary.latestTurnStatus, .failed)
        XCTAssertNil(summary.pendingState)
        let calls = await counter.count
        XCTAssertEqual(calls, 0)
    }

    func testModelPassBudgetStopsBeforeAnotherHTTPRequest() async throws {
        let backend = CodexResponsesBackend(configuration: .init(maximumBufferedEvents: 1, maximumModelPasses: 1),
            urlSession: makeTestURLSession())
        await TestURLProtocol.enqueue(.init(body: Data("""
        data: {"type":"response.output_item.done","item":{"type":"function_call","name":"lookup","call_id":"call","arguments":"{}"}}

        data: {"type":"response.completed","response":{"id":"response"}}

        """.utf8)))
        let stream = try await backend.beginTurn(thread: .init(id: "thread"), history: [], message: Request(text: "Go"),
            instructions: "", responseFormat: nil, streamedStructuredOutput: nil,
            tools: [.init(name: "lookup", description: "lookup", inputSchema: .object([:]))], session: demoSession())
        var calls = 0
        do {
            for try await event in stream.events {
                if case let .toolCallRequested(invocation) = event {
                    calls += 1
                    try await stream.submitToolResult(.success(invocation: invocation, text: "Done"), for: invocation.id)
                }
            }
            XCTFail("Expected the model-pass budget to fail")
        } catch { XCTAssertEqual((error as? AgentRuntimeError)?.executionLimit, .modelPasses) }
        XCTAssertEqual(calls, 1)
    }

    func testInvalidLimitsFailAtRuntimeConstruction() {
        for limits in [AgentTurnLimits(maximumToolCalls: -1), .init(maximumDuration: .nan), .init(maximumDuration: .infinity)] {
            XCTAssertThrowsError(try AgentRuntime(configuration: .init(authProvider: DemoChatGPTAuthProvider(),
                secureStore: secureStore(), backend: LimitBatchBackend(), approvalPresenter: AutoApprovalPresenter(),
                stateStore: InMemoryRuntimeStateStore(), turnLimits: limits))) { error in
                XCTAssertEqual((error as? AgentRuntimeError)?.code, "invalid_turn_limits")
            }
        }
    }

    func testCompletionAndDeadlineHaveOneConsistentWinner() throws {
        let expired = AgentTurnBudget(limits: .init())
        XCTAssertTrue(expired.expire())
        XCTAssertThrowsError(try expired.acceptCompletion()) {
            XCTAssertEqual(($0 as? AgentRuntimeError)?.executionLimit, .duration)
        }
        let completed = AgentTurnBudget(limits: .init())
        try completed.acceptCompletion()
        XCTAssertFalse(completed.expire())
        XCTAssertNil(completed.error)
    }

    private func secureStore() -> KeychainSessionSecureStore {
        .init(service: "CodexKit.LimitTests", account: UUID().uuidString)
    }
}

private struct LimitOutput: AgentStructuredOutput {
    let value: String
    static let responseFormat = AgentStructuredOutputFormat(name: "value", schema: .object(properties: ["value": .string()]))
}

private actor LimitCallCounter {
    var count = 0
    func record() { count += 1 }
}

private struct LimitBatchBackend: AgentBackend {
    func createThread(session: ChatGPTSession) async throws -> AgentThread { AgentThread(id: UUID().uuidString) }
    func resumeThread(id: String, session: ChatGPTSession) async throws -> AgentThread { AgentThread(id: id) }
    func beginTurn(thread: AgentThread, history: [AgentMessage], message: Request, instructions: String,
        responseFormat: AgentStructuredOutputFormat?, streamedStructuredOutput: AgentStreamedStructuredOutputRequest?,
        tools: [ToolDefinition], session: ChatGPTSession) async throws -> AgentTurnStream {
        AgentTurnStream(events: AsyncThrowingStream { continuation in
            continuation.yield(.turnStarted(.init(id: "turn", threadID: thread.id)))
            continuation.yield(.toolCallsRequested((0..<2).map { .init(id: "call-\($0)", threadID: thread.id,
                turnID: "turn", toolName: "lookup", arguments: .null) }))
            continuation.yield(.turnCompleted(.init(threadID: thread.id, turnID: "turn")))
            continuation.finish()
        })
    }
}
