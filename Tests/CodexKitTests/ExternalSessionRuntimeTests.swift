@testable import CodexKit
import CodexKitSQLite
import XCTest

final class ExternalSessionRuntimeTests: XCTestCase {
    override func setUp() async throws { await TestURLProtocol.reset() }
    override func tearDown() async throws { await TestURLProtocol.reset() }

    func testTokenRotationBetweenToolPassesKeepsOneExecution() async throws {
        let clock = ExternalFixtureClock()
        let source = ExternalFixtureSource(externalSession(expiry: clock.now().addingTimeInterval(1000)))
        let owner = ExternalFixtureOwner {
            await source.set(externalSession(token: "renewed", expiry: clock.now().addingTimeInterval(3600)))
        }
        let manager = externalManager(clock: clock)
        _ = try await manager.connectExternalSession(source: source, owner: owner)
        let calls = ExternalCallCounter()
        let runtime = try runtime(manager: manager, tools: [.init(
            definition: .init(name: "lookup", description: "Synthetic lookup", inputSchema: .object([:]), approvalPolicy: .automatic),
            executor: AnyToolExecutor { invocation, _ in
                await calls.increment()
                clock.advance(1200)
                return .success(invocation: invocation, text: "tool completed exactly once")
            })])
        let thread = try await runtime.createThread()
        await TestURLProtocol.enqueue(.init(headers: ["Content-Type": "text/event-stream"], body: toolPass, inspect: { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer borrowed-access")
        }))
        await TestURLProtocol.enqueue(.init(headers: ["Content-Type": "text/event-stream"], body: finalPass, inspect: { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer renewed")
        }))
        let result = try await runtime.send(Request(text: "Run lookup"), in: thread.id)
        XCTAssertEqual(result, "Finished")
        let toolCalls = await calls.count
        let renewals = await owner.requests
        XCTAssertEqual(toolCalls, 1)
        XCTAssertEqual(renewals, 1)
    }

    func test401AfterToolPassRetriesOnlyRejectedPass() async throws {
        let source = ExternalFixtureSource()
        let owner = ExternalFixtureOwner { await source.set(externalSession(token: "renewed")) }
        let manager = externalManager()
        _ = try await manager.connectExternalSession(source: source, owner: owner)
        let calls = ExternalCallCounter()
        let runtime = try runtime(manager: manager, tools: [.init(
            definition: .init(name: "lookup", description: "Lookup", inputSchema: .object([:]), approvalPolicy: .automatic),
            executor: AnyToolExecutor { invocation, _ in await calls.increment(); return .success(invocation: invocation, text: "one") })])
        let thread = try await runtime.createThread()
        await TestURLProtocol.enqueue(.init(headers: ["Content-Type": "text/event-stream"], body: toolPass))
        await TestURLProtocol.enqueue(.init(statusCode: 401, body: Data()))
        await TestURLProtocol.enqueue(.init(headers: ["Content-Type": "text/event-stream"], body: finalPass, inspect: { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer renewed")
        }))
        let result = try await runtime.send(Request(text: "Go"), in: thread.id)
        XCTAssertEqual(result, "Finished")
        let count = await calls.count
        XCTAssertEqual(count, 1)
    }

    func testBoundRetryDoesNotLoopAnd403NeverRequestsRenewal() async throws {
        for status in [401, 403] {
            let source = ExternalFixtureSource()
            let owner = ExternalFixtureOwner { await source.set(externalSession(token: "renewed")) }
            let manager = externalManager()
            _ = try await manager.connectExternalSession(source: source, owner: owner)
            let runtime = try runtime(manager: manager)
            let thread = try await runtime.createThread()
            await TestURLProtocol.enqueue(.init(statusCode: status, body: Data()))
            if status == 401 { await TestURLProtocol.enqueue(.init(statusCode: status, body: Data())) }
            do { _ = try await runtime.send(Request(text: "Go"), in: thread.id); XCTFail("Expected rejection") }
            catch { XCTAssertEqual((error as? AgentRuntimeError)?.http?.statusCode, status) }
            let count = await owner.requests
            XCTAssertEqual(count, status == 401 ? 1 : 0)
        }
    }

    func testModelDiscoveryAndCompactionUseExternalRecovery() async throws {
        let source = ExternalFixtureSource()
        let owner = ExternalFixtureOwner { await source.set(externalSession(token: "renewed")) }
        let manager = externalManager()
        _ = try await manager.connectExternalSession(source: source, owner: owner)
        let runtime = try runtime(manager: manager)
        await TestURLProtocol.enqueue(.init(statusCode: 401, body: Data()))
        await TestURLProtocol.enqueue(.init(body: Data(#"{"models":[]}"#.utf8)))
        _ = try await runtime.listModels(policy: .refresh)
        let thread = try await runtime.createThread()
        await source.set(externalSession(token: "third"))
        await TestURLProtocol.enqueue(.init(body: streamedCompactionReply(), inspect: { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer third")
        }))
        let compacted = try await runtime.compactThreadContext(id: thread.id)
        XCTAssertEqual(compacted.providerContext?.payload.objectValue?["items"]?.arrayValue?.last?.objectValue?["type"], .string("compaction"))
    }

    func testPersistedConversationCannotResumeUnderDifferentUserOrSource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteRuntimeStateStore(url: root.appendingPathComponent("state.sqlite"))
        let first = externalManager()
        _ = try await first.connectExternalSession(source: ExternalFixtureSource())
        let original = try runtime(manager: first, store: store)
        let thread = try await original.createThread()
        for session in [externalSession(user: "another"), externalSession(source: "another"), externalSession(account: "another")] {
            let manager = externalManager()
            _ = try await manager.connectExternalSession(source: ExternalFixtureSource(session))
            let restored = try runtime(manager: manager, store: store)
            _ = try await restored.restore()
            do { _ = try await restored.resumeThread(id: thread.id); XCTFail("Cross-account resume") }
            catch { XCTAssertEqual(error as? ChatGPTSessionError, .accountChanged) }
        }
    }

    func testDisconnectWhileToolIsSuspendedRejectsLateResult() async throws {
        let source = ExternalFixtureSource()
        let manager = externalManager()
        _ = try await manager.connectExternalSession(source: source)
        let gate = ExternalFixtureGate()
        let runtime = try runtime(manager: manager, tools: [.init(
            definition: .init(name: "lookup", description: "Lookup", inputSchema: .object([:]), approvalPolicy: .automatic),
            executor: AnyToolExecutor { invocation, _ in await gate.wait(); return .success(invocation: invocation, text: "late private result") })])
        let thread = try await runtime.createThread()
        await TestURLProtocol.enqueue(.init(headers: ["Content-Type": "text/event-stream"], body: toolPass))
        let sending = Task { try await runtime.send(Request(text: "Go"), in: thread.id) }
        for _ in 0..<1000 { if await gate.entered { break }; try await Task.sleep(for: .milliseconds(1)) }
        let entered = await gate.entered
        XCTAssertTrue(entered)
        try await runtime.signOut()
        await gate.open()
        do { _ = try await sending.value; XCTFail("Expected cancellation") } catch { }
        let messages = await runtime.messages(for: thread.id)
        XCTAssertFalse(messages.contains { $0.text.contains("late private result") })
    }

    func testDefaultSessionDiagnosticsAreRedacted() {
        let session = externalSession()
        for text in [String(describing: session), String(reflecting: session), String(reflecting: session.account)] {
            XCTAssertFalse(text.contains(session.accessToken))
            XCTAssertFalse(text.contains(session.account.email))
            XCTAssertFalse(text.contains(session.account.id))
        }
    }

    private func runtime(manager: ChatGPTSessionManager, tools: [AgentRuntime.ToolRegistration] = [],
                         store: any RuntimeStateStoring = InMemoryRuntimeStateStore()) throws -> AgentRuntime {
        try AgentRuntime(configuration: .init(sessionProvider: manager,
            backend: CodexResponsesBackend(configuration: .init(requestRetryPolicy: .init(maxAttempts: 1)), urlSession: makeTestURLSession()),
            approvalPresenter: AutoApprovalPresenter(), stateStore: store,
            tools: tools, contextCompaction: .init(isEnabled: true, strategy: .remoteOnly)))
    }

    private var toolPass: Data {
        Data("""
        data: {"type":"response.output_item.done","item":{"type":"function_call","name":"lookup","arguments":"{}","call_id":"call-one"}}

        data: {"type":"response.completed","response":{"id":"first"}}

        """.utf8)
    }

    private var finalPass: Data {
        Data("""
        data: {"type":"response.output_item.done","item":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Finished"}]}}

        data: {"type":"response.completed","response":{"id":"final"}}

        """.utf8)
    }
}

private actor ExternalCallCounter {
    var count = 0
    func increment() { count += 1 }
}
