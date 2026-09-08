@testable import CodexKit
import CodexKitUI
import CodexKitSQLite
import Combine
import XCTest

final class AuditRegressionTests: XCTestCase {
    func testResponses401RecoversReplacementSession() async throws {
        await TestURLProtocol.reset()
        let secureStore = auditSecureStore()
        defer { try? secureStore.deleteSession() }
        let backend = CodexResponsesBackend(urlSession: makeTestURLSession())
        let runtime = try auditRuntime(backend: backend, secureStore: secureStore)
        _ = try await runtime.useSession(demoSession())
        let thread = try await runtime.createThread()
        await TestURLProtocol.enqueue(.init(statusCode: 401, body: Data("{}".utf8), inspect: { _ in
            try secureStore.saveSession(demoSession(accessToken: "replacement-token"))
        }))
        await TestURLProtocol.enqueue(.init(headers: ["Content-Type": "text/event-stream"], body: auditSSE(text: "Recovered")))
        do {
            let reply = try await runtime.send(Request(text: "Hello"), in: thread.id)
            XCTAssertEqual(reply, "Recovered")
        } catch {
            XCTFail("Replacement session was available, but recovery failed: \(error)")
        }
        await TestURLProtocol.reset()
    }

    func testRefreshCannotRestoreSessionAfterSignOut() async throws {
        await TestURLProtocol.reset()
        let secureStore = auditSecureStore()
        defer { try? secureStore.deleteSession() }
        let manager = ChatGPTSessionManager(
            authProvider: try ChatGPTAuthProvider(method: .oauth, urlSession: makeTestURLSession()),
            secureStore: secureStore
        )
        _ = try await manager.useSession(demoSession())
        let started = expectation(description: "refresh request started")
        let gate = AuditBlockingGate()
        let token = try makeUnsignedJWT(claims: [
            "chatgpt_account_id": "demo-account", "chatgpt_plan_type": "plus",
            "exp": Int(Date().addingTimeInterval(3600).timeIntervalSince1970),
        ])
        await TestURLProtocol.enqueue(.init(body: try JSONEncoder().encode([
            "access_token": token, "id_token": token, "refresh_token": "replacement-refresh",
        ]), inspect: { _ in started.fulfill(); gate.wait() }))
        let refresh = Task { try await manager.refresh(reason: .unauthorized) }
        await fulfillment(of: [started], timeout: 3)
        try await manager.signOut()
        gate.open()
        do { _ = try await refresh.value; XCTFail("Expected stale refresh cancellation") } catch is CancellationError { }
        let session = await manager.currentSession()
        XCTAssertNil(session, "A late refresh must not sign the user back in")
        XCTAssertNil(try secureStore.loadSession(), "A late refresh must not repopulate Keychain")
        await TestURLProtocol.reset()
    }

    func testConcurrentRefreshesShareOneRequest() async throws {
        await TestURLProtocol.reset()
        let secureStore = auditSecureStore()
        defer { try? secureStore.deleteSession() }
        let manager = ChatGPTSessionManager(authProvider: try ChatGPTAuthProvider(method: .oauth,
            urlSession: makeTestURLSession()), secureStore: secureStore)
        _ = try await manager.useSession(demoSession())
        let started = expectation(description: "refresh request started")
        let gate = AuditBlockingGate()
        defer { gate.open() }
        let token = try makeUnsignedJWT(claims: ["chatgpt_account_id": "demo-account",
            "exp": Int(Date().addingTimeInterval(3600).timeIntervalSince1970)])
        await TestURLProtocol.enqueue(.init(body: try JSONEncoder().encode([
            "access_token": token, "id_token": token, "refresh_token": "next-refresh"
        ]), inspect: { _ in started.fulfill(); gate.wait() }))
        let first = Task { try await manager.refresh(reason: .unauthorized) }
        await fulfillment(of: [started], timeout: 3)
        let second = Task { try await manager.refresh(reason: .unauthorized) }
        // Keep the first HTTP request suspended while the second caller joins it.
        try await Task.sleep(for: .milliseconds(50))
        gate.open()
        let results = try await [first.value, second.value]
        XCTAssertEqual(results[0], results[1])
        XCTAssertEqual(results[0].accessToken, token)
        await TestURLProtocol.reset()
    }

    func testCancellingRefreshCallerDoesNotCancelOtherWaitersOrStartAnotherRequest() async throws {
        await TestURLProtocol.reset()
        let secureStore = auditSecureStore()
        defer { try? secureStore.deleteSession() }
        let manager = ChatGPTSessionManager(authProvider: try ChatGPTAuthProvider(method: .oauth,
            urlSession: makeTestURLSession()), secureStore: secureStore)
        _ = try await manager.useSession(demoSession())
        let started = expectation(description: "refresh request started")
        let gate = AuditBlockingGate()
        defer { gate.open() }
        let token = try makeUnsignedJWT(claims: ["chatgpt_account_id": "demo-account",
            "exp": Int(Date().addingTimeInterval(3600).timeIntervalSince1970)])
        await TestURLProtocol.enqueue(.init(body: try JSONEncoder().encode([
            "access_token": token, "id_token": token, "refresh_token": "next-refresh"
        ]), inspect: { _ in started.fulfill(); gate.wait() }))
        let first = Task { try await manager.refresh(reason: .unauthorized) }
        await fulfillment(of: [started], timeout: 3)
        let second = Task { try await manager.refresh(reason: .unauthorized) }
        try await Task.sleep(for: .milliseconds(50))
        let cancelledAt = Date()
        first.cancel()
        do { _ = try await first.value; XCTFail("Expected caller cancellation") } catch is CancellationError { }
        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 1, "Cancellation should not wait for the HTTP response")
        let third = Task { try await manager.refresh(reason: .unauthorized) }
        try await Task.sleep(for: .milliseconds(50))
        gate.open()
        let secondSession = try await second.value
        let thirdSession = try await third.value
        XCTAssertEqual(secondSession.accessToken, token)
        XCTAssertEqual(thirdSession.accessToken, token)
        await TestURLProtocol.reset()
    }

    func testRefreshCannotOverwriteSuppliedSession() async throws {
        await TestURLProtocol.reset()
        let secureStore = auditSecureStore()
        defer { try? secureStore.deleteSession() }
        let manager = ChatGPTSessionManager(authProvider: try ChatGPTAuthProvider(method: .oauth,
            urlSession: makeTestURLSession()), secureStore: secureStore)
        _ = try await manager.useSession(demoSession())
        let started = expectation(description: "refresh request started")
        let gate = AuditBlockingGate()
        defer { gate.open() }
        let token = try makeUnsignedJWT(claims: ["chatgpt_account_id": "demo-account"])
        await TestURLProtocol.enqueue(.init(body: try JSONEncoder().encode([
            "access_token": token, "id_token": token, "refresh_token": "old-refresh"
        ]), inspect: { _ in started.fulfill(); gate.wait() }))
        let refresh = Task { try await manager.refresh(reason: .unauthorized) }
        await fulfillment(of: [started], timeout: 3)
        let replacement = demoSession(accessToken: "host-replacement")
        _ = try await manager.useSession(replacement)
        gate.open()
        do { _ = try await refresh.value; XCTFail("Expected stale refresh cancellation") } catch is CancellationError { }
        let current = await manager.currentSession()
        XCTAssertEqual(current, replacement)
        XCTAssertEqual(try secureStore.loadSession(), replacement)
        await TestURLProtocol.reset()
    }

    func testResponsesContextFailureCompactsAndRetriesInitialRequest() async throws {
        await TestURLProtocol.reset()
        let secureStore = auditSecureStore()
        defer { try? secureStore.deleteSession() }
        let runtime = try AgentRuntime(configuration: .init(authProvider: DemoChatGPTAuthProvider(),
            secureStore: secureStore, backend: CodexResponsesBackend(urlSession: makeTestURLSession()),
            approvalPresenter: AutoApprovalPresenter(), stateStore: InMemoryRuntimeStateStore(),
            contextCompaction: .init(isEnabled: true, strategy: .localOnly,
                trigger: .init(estimatedTokenThreshold: 1_000_000))))
        _ = try await runtime.useSession(demoSession())
        let thread = try await runtime.createThread()
        for _ in 0..<3 {
            await TestURLProtocol.enqueue(.init(headers: ["Content-Type": "text/event-stream"], body: auditSSE(text: "Previous reply")))
            _ = try await runtime.send(Request(text: "Previous context"), in: thread.id)
        }
        await TestURLProtocol.enqueue(.init(statusCode: 400,
            body: Data(#"{"error":{"code":"context_length_exceeded","message":"Maximum context length exceeded."}}"#.utf8)))
        await TestURLProtocol.enqueue(.init(headers: ["Content-Type": "text/event-stream"], body: auditSSE(text: "Compacted reply")))
        let reply = try await runtime.send(Request(text: "Last request"), in: thread.id)
        XCTAssertEqual(reply, "Compacted reply")
        let context = try await runtime.fetchThreadContextState(id: thread.id)
        XCTAssertEqual(context?.generation, 1)
        let messages = await runtime.messages(for: thread.id)
        XCTAssertEqual(messages.filter { $0.text == "Last request" }.count, 1)
        await TestURLProtocol.reset()
    }

    @MainActor
    func testReplacingToolDuringApprovalPreservesApprovedExecutor() async throws {
        let secureStore = auditSecureStore()
        defer { try? secureStore.deleteSession() }
        let inbox = ApprovalInbox()
        let definition = ToolDefinition(name: "demo_lookup_profile", description: "Original tool",
            inputSchema: .object([:]), approvalPolicy: .requiresApproval)
        let runtime = try AgentRuntime(configuration: .init(authProvider: DemoChatGPTAuthProvider(),
            secureStore: secureStore, backend: InMemoryAgentBackend(), approvalPresenter: inbox,
            stateStore: InMemoryRuntimeStateStore(), tools: [.init(definition: definition,
                executor: AnyToolExecutor { invocation, _ in .success(invocation: invocation, text: "original executor") })]))
        _ = try await runtime.useSession(demoSession())
        let thread = try await runtime.createThread()
        let sending = Task { try await runtime.send(Request(text: "Use the tool"), in: thread.id) }
        for _ in 0..<500 {
            if inbox.currentRequest != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(inbox.currentRequest)
        try await runtime.replaceTool(definition, executor: AnyToolExecutor { invocation, _ in
            .success(invocation: invocation, text: "replacement executor")
        })
        inbox.approveCurrent()
        let reply = try await sending.value
        XCTAssertTrue(reply.contains("original executor"))
        XCTAssertFalse(reply.contains("replacement executor"))
    }

    func testStructuredStreamAlsoRejectsPrematureCompletion() async throws {
        let secureStore = auditSecureStore()
        defer { try? secureStore.deleteSession() }
        let runtime = try auditRuntime(backend: AuditPrematureBackend(), secureStore: secureStore)
        _ = try await runtime.useSession(demoSession())
        let thread = try await runtime.createThread()
        do {
            let stream = try await runtime.stream(Request(text: "Decide"), in: thread.id, response: AuditEnumOutput.self)
            for try await _ in stream { }
            XCTFail("Expected an unfinished structured turn to fail")
        } catch {
            XCTAssertEqual((error as? AgentRuntimeError)?.code, "turn_summary_missing")
        }
        let summary = try await runtime.fetchThreadSummary(id: thread.id)
        XCTAssertEqual(summary.latestTurnStatus, .failed)
    }

    func testExistingSubscriptionSurvivesDeactivation() {
        let center = AgentRuntimeObservationCenter()
        let seen = AuditValues<[AgentMessage]>()
        let subscription = center.messagePublisher(for: "thread").sink { seen.append($0) }
        center.send(.messagesChanged(threadID: "thread", messages: [
            AgentMessage(threadID: "thread", role: .assistant, text: "before")
        ]))
        center.deactivateThread(id: "thread", activeThreads: [])
        center.send(.messagesChanged(threadID: "thread", messages: [
            AgentMessage(threadID: "thread", role: .assistant, text: "after")
        ]))
        XCTAssertEqual(seen.values.last?.last?.text, "after")
        withExtendedLifetime(subscription) {}
    }

    func testEveryThreadPublisherSurvivesReactivation() {
        let center = AgentRuntimeObservationCenter()
        let threads = AuditValues<AgentThread?>()
        let summaries = AuditValues<AgentThreadSummary?>()
        let contexts = AuditValues<AgentThreadContextState?>()
        let usages = AuditValues<AgentThreadContextUsage?>()
        let subscriptions = [
            center.threadPublisher(for: "thread").sink { threads.append($0) },
            center.threadSummaryPublisher(for: "thread").sink { summaries.append($0) },
            center.threadContextStatePublisher(for: "thread").sink { contexts.append($0) },
            center.threadContextUsagePublisher(for: "thread").sink { usages.append($0) },
        ]
        center.deactivateThread(id: "thread", activeThreads: [])
        let thread = AgentThread(id: "thread")
        let summary = AgentThreadSummary(threadID: thread.id, createdAt: Date(), updatedAt: Date(), itemCount: 2)
        let context = AgentThreadContextState(threadID: thread.id, effectiveMessages: [])
        let usage = AgentThreadContextUsage(threadID: thread.id, visibleEstimatedTokenCount: 20, effectiveEstimatedTokenCount: 10)
        center.send(.threadChanged(thread))
        center.send(.threadSummaryChanged(summary))
        center.send(.threadContextStateChanged(threadID: thread.id, state: context))
        center.send(.threadContextUsageChanged(threadID: thread.id, usage: usage))
        XCTAssertEqual(threads.values.last!, thread)
        XCTAssertEqual(summaries.values.last!, summary)
        XCTAssertEqual(contexts.values.last!, context)
        XCTAssertEqual(usages.values.last!, usage)
        withExtendedLifetime(subscriptions) {}
    }

    func testRetryDoesNotReplayStructuredSnapshots() async throws {
        await TestURLProtocol.reset()
        let payload = CodexResponsesStructuredStreamParser.openTag + #"{"priority":"high"}"#
        let data = try JSONEncoder().encode(JSONValue.object([
            "type": .string("response.output_text.delta"), "delta": .string(payload)
        ]))
        await TestURLProtocol.enqueue(.init(headers: ["Content-Type": "text/event-stream"],
            body: Data("data: ".utf8) + data + Data("\n\n".utf8)))
        let backend = CodexResponsesBackend(configuration: .init(requestRetryPolicy: .init(initialBackoff: 0)),
            urlSession: makeTestURLSession())
        let stream = try await backend.beginTurn(thread: AgentThread(id: "structured-retry"), history: [],
            message: Request(text: "Decide"), instructions: "", responseFormat: nil,
            streamedStructuredOutput: .init(responseFormat: AuditEnumOutput.responseFormat, options: .init()), tools: [], session: demoSession())
        var snapshots = 0
        do {
            for try await event in stream.events {
                if case .structuredOutputPartial = event { snapshots += 1 }
            }
            XCTFail("Expected disconnect after published structured output")
        } catch {
            XCTAssertEqual((error as? AgentRuntimeError)?.code, "responses_stream_disconnected")
        }
        XCTAssertEqual(snapshots, 1)
        await TestURLProtocol.reset()
    }

    func testPrematureBackendFinishIsNotSuccessfulReply() async throws {
        let secureStore = auditSecureStore()
        defer { try? secureStore.deleteSession() }
        let runtime = try auditRuntime(backend: AuditPrematureBackend(), secureStore: secureStore)
        _ = try await runtime.useSession(demoSession())
        let thread = try await runtime.createThread()
        do {
            let reply = try await runtime.send(Request(text: "Hello"), in: thread.id)
            XCTFail("Returned success without turnCompleted: \(reply)")
        } catch { }
        let threads = await runtime.activeThreads()
        XCTAssertNotEqual(threads.first?.status, .streaming)
    }

    func testStreamedSchemaRejectsDisallowedEnumValue() async throws {
        await TestURLProtocol.reset()
        let secureStore = auditSecureStore()
        defer { try? secureStore.deleteSession() }
        let runtime = try auditRuntime(
            backend: CodexResponsesBackend(urlSession: makeTestURLSession()), secureStore: secureStore
        )
        _ = try await runtime.useSession(demoSession())
        let thread = try await runtime.createThread()
        await TestURLProtocol.enqueue(.init(headers: ["Content-Type": "text/event-stream"], body: auditSSE(
            text: "Done<codexkit-structured-output>{\"priority\":\"INVALID\"}</codexkit-structured-output>"
        )))
        var acceptedInvalid = false
        do {
            let stream = try await runtime.stream(Request(text: "Decide"), in: thread.id, response: AuditEnumOutput.self)
            for try await event in stream {
                if case let .structuredOutputCommitted(value) = event {
                    acceptedInvalid = value.priority == "INVALID"
                }
            }
            XCTFail("Expected schema validation failure")
        } catch {
            XCTAssertEqual((error as? AgentRuntimeError)?.code, "structured_output_invalid")
        }
        let metadata = try await runtime.fetchLatestStructuredOutputMetadata(id: thread.id)
        XCTAssertNil(metadata, "Invalid output must not be stored as a committed payload")
        XCTAssertFalse(acceptedInvalid, "The declared enum is [low, high], but INVALID was committed")
        await TestURLProtocol.reset()
    }

    func testRetryDoesNotDuplicateVisibleDeltas() async throws {
        await TestURLProtocol.reset()
        let delta = Data("data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hello\"}\n\n".utf8)
        await TestURLProtocol.enqueue(.init(headers: ["Content-Type": "text/event-stream"], body: delta))
        await TestURLProtocol.enqueue(.init(headers: ["Content-Type": "text/event-stream"], body: delta + auditSSE(text: "Hello")))
        let backend = CodexResponsesBackend(configuration: .init(requestRetryPolicy: .init(initialBackoff: 0)),
            urlSession: makeTestURLSession())
        let stream = try await backend.beginTurn(thread: AgentThread(id: "retry-audit"), history: [],
            message: Request(text: "Hello"), instructions: "", responseFormat: nil,
            streamedStructuredOutput: nil, tools: [], session: demoSession())
        var text = ""
        do {
            for try await event in stream.events {
                if case let .assistantMessageDelta(_, _, delta) = event { text += delta }
            }
            XCTFail("Expected disconnect after visible output")
        } catch let error as AgentRuntimeError {
            XCTAssertEqual(error.code, "responses_stream_disconnected")
        }
        XCTAssertEqual(text, "Hello", "A retry silently replayed already-published text")
        await TestURLProtocol.reset()
    }

    func testDeactivationDuringTurnDoesNotLeaveDurableStreamingState() async throws {
        let secureStore = auditSecureStore()
        defer { try? secureStore.deleteSession() }
        let backend = AuditControlledBackend()
        let stateStore = InMemoryRuntimeStateStore()
        let runtime = try AgentRuntime(configuration: .init(authProvider: DemoChatGPTAuthProvider(),
            secureStore: secureStore, backend: backend, approvalPresenter: AutoApprovalPresenter(), stateStore: stateStore))
        _ = try await runtime.useSession(demoSession())
        let thread = try await runtime.createThread()
        let stream = try await runtime.stream(Request(text: "Hello"), in: thread.id)
        do {
            for try await event in stream {
                if case .turnStarted = event {
                    await runtime.deactivateThread(id: thread.id)
                    await backend.complete()
                }
            }
        } catch { }
        let state = try await stateStore.loadState()
        XCTAssertNotEqual(state.threads.first?.status, .streaming)
    }

    func testNewSQLiteThreadKeepsMessageWorkingSetBounded() async throws {
        let secureStore = auditSecureStore()
        defer { try? secureStore.deleteSession() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CodexKitAudit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let stateStore = try SQLiteRuntimeStateStore(url: directory.appendingPathComponent("runtime.sqlite"))
        let runtime = try AgentRuntime(configuration: .init(authProvider: DemoChatGPTAuthProvider(),
            secureStore: secureStore, backend: InMemoryAgentBackend(), approvalPresenter: AutoApprovalPresenter(),
            stateStore: stateStore, threadActivationPolicy: .init(maximumMessageCount: 2, maximumHistoryRecordCount: 6)))
        // Bounds also apply when the host supplies a session without restoring first.
        _ = try await runtime.useSession(demoSession())
        let thread = try await runtime.createThread()
        for _ in 0..<3 { _ = try await runtime.send(Request(text: "Hello"), in: thread.id) }
        let messages = await runtime.messages(for: thread.id)
        XCTAssertLessThanOrEqual(messages.count, 2, "Normalization restored messages discarded by the bound")
    }

    @MainActor
    func testUIStoreDoesNotDuplicateUserMessageOrDisplayAnotherThreadsReply() async throws {
        let secureStore = auditSecureStore()
        defer { try? secureStore.deleteSession() }
        let backend = AuditControlledBackend()
        let runtime = try auditRuntime(backend: backend, secureStore: secureStore)
        _ = try await runtime.useSession(demoSession())
        let first = try await runtime.createThread(title: "first")
        let second = try await runtime.createThread(title: "second")
        let store = AgentRuntimeStore(runtime: runtime)
        await store.activateThread(id: first.id)
        let sending = Task { await store.send("user message") }
        for _ in 0..<500 {
            if store.latestProgress != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(store.latestProgress)
        XCTAssertEqual(store.messages.filter { $0.role == .user }.count, 1)
        await store.activateThread(id: second.id)
        await backend.complete()
        await sending.value
        XCTAssertTrue(store.messages.isEmpty, "Reply from first thread was installed into selected second thread")
    }
}

private func auditSecureStore() -> KeychainSessionSecureStore {
    KeychainSessionSecureStore(service: "CodexKit.Audit", account: UUID().uuidString)
}

private func auditRuntime(backend: any AgentBackend, secureStore: KeychainSessionSecureStore) throws -> AgentRuntime {
    try AgentRuntime(configuration: .init(
        authProvider: DemoChatGPTAuthProvider(), secureStore: secureStore,
        backend: backend, approvalPresenter: AutoApprovalPresenter(), stateStore: InMemoryRuntimeStateStore()
    ))
}

private func auditSSE(text: String) -> Data {
    let message = JSONValue.object([
        "type": .string("response.output_item.done"), "item": .object([
            "type": .string("message"), "role": .string("assistant"),
            "content": .array([.object(["type": .string("output_text"), "text": .string(text)])]),
        ]),
    ])
    let encoded = String(decoding: try! JSONEncoder().encode(message), as: UTF8.self)
    return Data("data: \(encoded)\n\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"response-audit\"}}\n\n".utf8)
}

private struct AuditEnumOutput: AgentStructuredOutput {
    let priority: String
    static let responseFormat = AgentStructuredOutputFormat(name: "priority", schema: .object(
        properties: ["priority": .string(enum: ["low", "high"])], required: ["priority"]
    ))
}

private final class AuditValues<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Value] = []
    var values: [Value] { lock.withLock { stored } }
    func append(_ value: Value) { lock.withLock { stored.append(value) } }
}

private final class AuditBlockingGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var opened = false
    func wait() {
        condition.lock()
        defer { condition.unlock() }
        let timeout = Date().addingTimeInterval(10)
        while !opened { if !condition.wait(until: timeout) { break } }
    }
    func open() {
        condition.lock()
        opened = true
        condition.broadcast()
        condition.unlock()
    }
}

private struct AuditPrematureBackend: AgentBackend {
    func createThread(session: ChatGPTSession) async throws -> AgentThread { AgentThread(id: UUID().uuidString) }
    func resumeThread(id: String, session: ChatGPTSession) async throws -> AgentThread { AgentThread(id: id) }
    func beginTurn(thread: AgentThread, history: [AgentMessage], message: Request, instructions: String,
        responseFormat: AgentStructuredOutputFormat?, streamedStructuredOutput: AgentStreamedStructuredOutputRequest?,
        tools: [ToolDefinition], session: ChatGPTSession) async throws -> AgentTurnStream {
        AgentTurnStream(events: AsyncThrowingStream { continuation in
            continuation.yield(.turnStarted(AgentTurn(id: "turn-audit", threadID: thread.id)))
            continuation.yield(.assistantMessageCompleted(AgentMessage(threadID: thread.id, role: .assistant, text: "partial")))
            continuation.finish()
        })
    }
}

private actor AuditControlledBackend: AgentBackend {
    private var continuation: AsyncThrowingStream<AgentBackendEvent, Error>.Continuation?
    private var threadID = ""
    func createThread(session: ChatGPTSession) async throws -> AgentThread { AgentThread(id: UUID().uuidString) }
    func resumeThread(id: String, session: ChatGPTSession) async throws -> AgentThread { AgentThread(id: id) }
    func beginTurn(thread: AgentThread, history: [AgentMessage], message: Request, instructions: String,
        responseFormat: AgentStructuredOutputFormat?, streamedStructuredOutput: AgentStreamedStructuredOutputRequest?,
        tools: [ToolDefinition], session: ChatGPTSession) async throws -> AgentTurnStream {
        threadID = thread.id
        let (events, continuation) = AsyncThrowingStream<AgentBackendEvent, Error>.makeStream()
        self.continuation = continuation
        continuation.yield(.turnStarted(AgentTurn(id: "turn-audit", threadID: thread.id)))
        continuation.yield(.progress(.init(threadID: thread.id, turnID: "turn-audit",
            content: .messageStarted(itemID: "message-audit", phase: nil))))
        return AgentTurnStream(events: events)
    }
    func complete() {
        continuation?.yield(.assistantMessageCompleted(AgentMessage(threadID: threadID, role: .assistant, text: "first reply")))
        continuation?.yield(.turnCompleted(.init(threadID: threadID, turnID: "turn-audit")))
        continuation?.finish()
    }
}
