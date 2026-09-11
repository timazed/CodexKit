@testable import CodexKit
import CodexKitRealm
import CodexKitSQLite
import XCTest

final class DeepAuditRegressionTests: XCTestCase {
    override func setUp() async throws { await TestURLProtocol.reset() }
    override func tearDown() async throws { await TestURLProtocol.reset() }

    func testManualCompactionCannotOverwriteANewerCompletedTurn() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for adapter in ["sqlite", "realm"] {
            let url = root.appendingPathComponent(adapter)
            let open: () throws -> any RuntimeStateStoring = {
                adapter == "sqlite" ? try SQLiteRuntimeStateStore(url: url) : try RealmRuntimeStateStore(url: url)
            }
            let store = try open()
            let backend = DeepCompactionBackend()
            let runtime = try AgentRuntime(configuration: .init(sessionProvider: DesignReadOnlyProvider(), backend: backend,
                approvalPresenter: AutoApprovalPresenter(), stateStore: store,
                contextCompaction: .init(isEnabled: true, mode: .manual, strategy: .remoteOnly)))
            let thread = try await runtime.createThread()
            _ = try await runtime.send(Request(text: "old question"), in: thread.id)
            let compaction = Task { try await runtime.compactThreadContext(id: thread.id) }
            try await backend.started.wait()
            do {
                _ = try await runtime.send(Request(text: "new question"), in: thread.id)
                XCTFail("A turn must not start while manual compaction holds the context")
            } catch { XCTAssertEqual((error as? AgentRuntimeError)?.code, "thread_busy") }
            do {
                _ = try await runtime.compactThreadContext(id: thread.id)
                XCTFail("A second compaction must not overlap the first")
            } catch { XCTAssertEqual((error as? AgentRuntimeError)?.code, "thread_busy") }
            await backend.release.resolve(.success(()))
            _ = try await compaction.value
            _ = try await runtime.send(Request(text: "new question"), in: thread.id)
            let transcript = await runtime.messages(for: thread.id)
            XCTAssertTrue(transcript.contains { $0.text == "new question" }, "The visible transcript should remain intact")
            let current = await runtime.effectiveHistory(for: thread.id)
            XCTAssertTrue(current.contains { $0.text == "new question" }, "Completed turn disappeared from effective context")
            let reopened = try open()
            let activation = try await reopened.loadThreadActivationState(id: thread.id, policy: .init())
            XCTAssertTrue(activation.effectiveMessages.contains { $0.text == "new question" }, "The lost context was persisted")
        }
    }

    func testCompactionExpandsStoredImageReferencesBeforeSending() async throws {
        let image = AgentImageAttachment(mimeType: "image/png", data: Data([137, 80, 78, 71]))
        let message = AgentMessage(threadID: "thread", role: .user, text: "Look", images: [image])
        let items = try CodexResponsesImageReferences.externalize([WorkingHistoryItem.visibleMessage(message).jsonValue])
        await TestURLProtocol.enqueue(.init(body: compactReply, inspect: { request in
            let value = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(requestBodyData(for: request)))
            let input = try XCTUnwrap(value.objectValue?["input"]?.arrayValue)
            let sent = input.first?.objectValue?["content"]?.arrayValue?.last?.objectValue?["image_url"]?.stringValue
            XCTAssertEqual(sent, image.dataURLString, "Internal image references must never reach the provider")
        }))
        let backend = CodexResponsesBackend(urlSession: makeTestURLSession())
        _ = try await backend.compactContext(thread: .init(id: "thread"), effectiveHistory: [message],
            providerContext: CodexResponsesProviderState(items: items).agentProviderContext,
            instructions: "", tools: [], session: demoSession())
    }

    func testCompactionRejectsAResponseBeyondTheConfiguredBudget() async throws {
        await TestURLProtocol.enqueue(.init(body: compactReply))
        let backend = CodexResponsesBackend(configuration: .init(maximumResponseBytes: 8), urlSession: makeTestURLSession())
        do {
            _ = try await backend.compactContext(thread: .init(id: "thread"), effectiveHistory: [], instructions: "", tools: [], session: demoSession())
            XCTFail("Compaction accepted a body larger than the configured response-byte limit")
        } catch { XCTAssertEqual((error as? AgentRuntimeError)?.executionLimit, .responseBytes) }
    }

    func testManualCompactionRecoversAnUnauthorizedSession() async throws {
        let provider = DesignSessionProvider()
        let backend = CodexResponsesBackend(urlSession: makeTestURLSession())
        let runtime = try AgentRuntime(configuration: .init(sessionProvider: provider, backend: backend,
            approvalPresenter: AutoApprovalPresenter(), stateStore: InMemoryRuntimeStateStore(),
            contextCompaction: .init(isEnabled: true, mode: .manual, strategy: .remoteOnly)))
        let thread = try await runtime.createThread()
        try await runtime.appendMessage(.init(threadID: thread.id, role: .user, text: "Existing history"))
        await TestURLProtocol.enqueue(.init(statusCode: 401, body: Data(#"{"error":{"code":"token_expired"}}"#.utf8)))
        await TestURLProtocol.enqueue(.init(body: compactReply))
        do { _ = try await runtime.compactThreadContext(id: thread.id) }
        catch { XCTFail("Compaction failed without using session recovery: \((error as? AgentRuntimeError)?.code ?? "other")") }
        let actions = await provider.actions
        XCTAssertEqual(actions, ["recover"])
    }

    func testAlreadyCancelledStartDoesNotLaunchOrPersistWork() async throws {
        let runtime = try AgentRuntime(configuration: .init(sessionProvider: DesignReadOnlyProvider(), backend: DesignBackend(),
            approvalPresenter: AutoApprovalPresenter(), stateStore: InMemoryRuntimeStateStore()))
        let thread = try await runtime.createThread()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await runtime.start(Request(text: "Must not run"), in: thread.id)
        }
        do {
            let execution = try await task.value
            try await execution.waitUntilReady()
            for try await _ in execution.events {}
            XCTFail("An already-cancelled start completed an execution")
        } catch is CancellationError {}
        let messages = await runtime.messages(for: thread.id)
        XCTAssertTrue(messages.isEmpty, "An already-cancelled start persisted messages")
    }

    func testOneShotOutputHonorsItsDeclaredEnum() async throws {
        let runtime = try AgentRuntime(configuration: .init(sessionProvider: DesignReadOnlyProvider(), backend: DeepJSONBackend(),
            approvalPresenter: AutoApprovalPresenter(), stateStore: InMemoryRuntimeStateStore()))
        let thread = try await runtime.createThread()
        do {
            let result = try await runtime.send(Request(text: "Go"), in: thread.id, response: DeepEnumOutput.self)
            XCTFail("One-shot structured output accepted invalid enum value: \(result.priority)")
        } catch { XCTAssertEqual((error as? AgentRuntimeError)?.code, "structured_output_schema_invalid") }
        let messages = await runtime.messages(for: thread.id)
        XCTAssertEqual(messages.map(\.role), [.user])
        let state = await runtime.thread(for: thread.id)
        XCTAssertEqual(state?.status, .failed)
    }

    func testMisspelledTopLevelPolicyDoesNotBecomeUnrestricted() async throws {
        for key in ["executionPolciy", "execution_policy", "metadata", "unknown"] {
            let body = try JSONSerialization.data(withJSONObject: ["id": "restricted", "instructions": "No tools",
                key: ["allowedToolNames": [], "maxToolCalls": 0]])
            await TestURLProtocol.enqueue(.init(body: body))
            let loader = AgentDefinitionSourceLoader(urlSession: makeTestURLSession())
            do {
                _ = try await loader.loadSkill(from: .remote(URL(string: "https://example.com/skill.json")!))
                XCTFail("Unknown root field was silently ignored: \(key)")
            } catch { XCTAssertEqual((error as? AgentDefinitionSourceError)?.code, "invalid_skill_definition") }
        }
    }

    func testStaleCompactionResultCannotInstallAMarkerOrReplaceChangedContext() async throws {
        let backend = DeepCompactionBackend()
        let store = InMemoryRuntimeStateStore()
        let runtime = try compactionRuntime(backend: backend, store: store)
        let thread = try await runtime.createThread()
        _ = try await runtime.send(Request(text: "Old"), in: thread.id)
        let task = Task { try await runtime.compactThreadContext(id: thread.id) }
        try await backend.started.wait()
        // Exercise the stale-result defense independently of the public operation reservation.
        try await runtime.appendMessage(.init(threadID: thread.id, role: .user, text: "New context"))
        await backend.release.resolve(.success(()))
        do { _ = try await task.value; XCTFail("Expected stale compaction rejection") }
        catch { XCTAssertEqual((error as? AgentRuntimeError)?.code, "context_changed_during_compaction") }
        let state = try await store.loadState()
        XCTAssertTrue(state.contextStateByThread[thread.id]?.effectiveMessages.contains { $0.text == "New context" } == true)
        XCTAssertEqual(state.contextStateByThread[thread.id]?.generation, 0)
        XCTAssertFalse((state.historyByThread[thread.id] ?? []).contains {
            if case let .systemEvent(event) = $0.item { return event.type == .contextCompacted }
            return false
        })
    }

    func testCancelledCompactionReleasesReservationWithoutChangingContext() async throws {
        let backend = DeepCompactionBackend()
        let store = InMemoryRuntimeStateStore()
        let runtime = try compactionRuntime(backend: backend, store: store)
        let thread = try await runtime.createThread()
        _ = try await runtime.send(Request(text: "Old"), in: thread.id)
        let before = try await store.loadState()
        let task = Task { try await runtime.compactThreadContext(id: thread.id) }
        try await backend.started.wait()
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        let after = try await store.loadState()
        XCTAssertEqual(after, before)
        _ = try await runtime.send(Request(text: "Next"), in: thread.id)
    }

    func testDeactivationWaitsForCompactionAndRestoreCannotEraseItsContext() async throws {
        let backend = DeepCompactionBackend()
        let store = InMemoryRuntimeStateStore()
        let runtime = try compactionRuntime(backend: backend, store: store)
        let thread = try await runtime.createThread()
        _ = try await runtime.send(Request(text: "Old"), in: thread.id)
        let task = Task { try await runtime.compactThreadContext(id: thread.id) }
        try await backend.started.wait()
        await runtime.deactivateThread(id: thread.id)
        let activeCount = await runtime.activeThreadCount()
        XCTAssertEqual(activeCount, 1)
        do { _ = try await runtime.restore(); XCTFail("Expected busy restoration") }
        catch { XCTAssertEqual((error as? AgentRuntimeError)?.code, "runtime_busy") }
        do { _ = try await runtime.resumeThread(id: thread.id); XCTFail("Expected busy resume") }
        catch { XCTAssertEqual((error as? AgentRuntimeError)?.code, "thread_busy") }
        await runtime.deactivateThread(id: thread.id)
        await backend.release.resolve(.success(()))
        _ = try await task.value
        let afterCount = await runtime.activeThreadCount()
        let state = try await store.loadState()
        XCTAssertEqual(afterCount, 0)
        XCTAssertEqual(state.contextStateByThread[thread.id]?.generation, 1)
    }

    func testActiveTurnBlocksManualCompaction() async throws {
        let ready = AgentTurnReadiness()
        let backend = DesignBackend(readiness: { try await ready.wait() })
        let runtime = try AgentRuntime(configuration: .init(sessionProvider: DesignReadOnlyProvider(), backend: backend,
            approvalPresenter: AutoApprovalPresenter(), stateStore: InMemoryRuntimeStateStore(),
            contextCompaction: .init(isEnabled: true, mode: .manual, strategy: .localOnly)))
        let thread = try await runtime.createThread()
        let execution = try await runtime.start(Request(text: "Running"), in: thread.id)
        do { _ = try await runtime.compactThreadContext(id: thread.id); XCTFail("Expected busy compaction") }
        catch { XCTAssertEqual((error as? AgentRuntimeError)?.code, "thread_busy") }
        await ready.resolve(.success(()))
        for try await _ in execution.events {}
        _ = try await runtime.compactThreadContext(id: thread.id)
    }

    private func compactionRuntime(backend: DeepCompactionBackend, store: any RuntimeStateStoring) throws -> AgentRuntime {
        try .init(configuration: .init(sessionProvider: DesignReadOnlyProvider(), backend: backend,
            approvalPresenter: AutoApprovalPresenter(), stateStore: store,
            contextCompaction: .init(isEnabled: true, mode: .manual, strategy: .remoteOnly)))
    }

    private var compactReply: Data {
        streamedCompactionReply()
    }
}

private actor DeepCompactionBackend: AgentBackend, AgentBackendContextCompacting {
    let started = AgentTurnReadiness()
    let release = AgentTurnReadiness()
    func createThread(session: ChatGPTSession) async throws -> AgentThread { .init(id: UUID().uuidString) }
    func resumeThread(id: String, session: ChatGPTSession) async throws -> AgentThread { .init(id: id) }
    func beginTurn(thread: AgentThread, history: [AgentMessage], message: Request, instructions: String,
        responseFormat: AgentStructuredOutputFormat?, streamedStructuredOutput: AgentStreamedStructuredOutputRequest?,
        tools: [ToolDefinition], session: ChatGPTSession) async throws -> AgentTurnStream {
        try await DesignBackend().beginTurn(thread: thread, history: history, message: message, instructions: instructions,
            responseFormat: responseFormat, streamedStructuredOutput: streamedStructuredOutput, tools: tools, session: session)
    }
    func compactContext(thread: AgentThread, effectiveHistory: [AgentMessage], instructions: String,
        tools: [ToolDefinition], session: ChatGPTSession) async throws -> AgentCompactionResult {
        await started.resolve(.success(()))
        try await release.wait()
        return .init(effectiveMessages: [.init(threadID: thread.id, role: .system, text: "Summary of old question")])
    }
}

private struct DeepJSONBackend: AgentBackend {
    func createThread(session: ChatGPTSession) async throws -> AgentThread { .init(id: UUID().uuidString) }
    func resumeThread(id: String, session: ChatGPTSession) async throws -> AgentThread { .init(id: id) }
    func beginTurn(thread: AgentThread, history: [AgentMessage], message: Request, instructions: String,
        responseFormat: AgentStructuredOutputFormat?, streamedStructuredOutput: AgentStreamedStructuredOutputRequest?,
        tools: [ToolDefinition], session: ChatGPTSession) async throws -> AgentTurnStream {
        let turn = AgentTurn(id: UUID().uuidString, threadID: thread.id)
        return .init(events: AsyncThrowingStream { continuation in
            continuation.yield(.turnStarted(turn))
            continuation.yield(.assistantMessageCompleted(.init(threadID: thread.id, role: .assistant, text: #"{"priority":"impossible"}"#)))
            continuation.yield(.turnCompleted(.init(threadID: thread.id, turnID: turn.id)))
            continuation.finish()
        })
    }
}

private struct DeepEnumOutput: AgentStructuredOutput {
    let priority: String
    static let responseFormat = AgentStructuredOutputFormat(name: "priority", schema:
        .object(properties: ["priority": .string(enum: ["low", "high"])], required: ["priority"]))
}
