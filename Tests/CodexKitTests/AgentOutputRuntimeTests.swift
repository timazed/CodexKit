@testable import CodexKit
import CodexKitSQLite
import CodexKitRealm
import XCTest

final class AgentOutputRuntimeTests: XCTestCase {
    typealias Record = AgentOutputDecoderTests.Record
    let source = "{\"id\":9007199254740993,\"text\":\"first\"}\n{\"id\":2,\"text\":\"second\"}\n"
    let format = AgentRecordResponseFormat(name: "records", record: Record.self)

    func testPreviewsAreNotPersistedAndCommitFollowsDurability() async throws {
        let gate = ToolExecutionGate()
        let backend = OutputTestBackend(source: source, beforeCompletion: { await gate.wait() })
        let fixture = try await OutputRuntimeFixture(backend: backend)
        defer { fixture.cleanUp() }
        let execution = try await fixture.runtime.start(Request(text: "Go"), in: fixture.thread.id, output: format)
        try await execution.waitUntilReady()
        var previews = 0, committed = 0, sawMessage = false, completed = false
        for try await event in execution.events {
            switch event {
            case let .format(context, .recordCompleted(index, _)):
                XCTAssertEqual(context.executionID, execution.id)
                XCTAssertEqual(context.messageID, "answer")
                XCTAssertEqual(index, previews); previews += 1
                let stored = try await fixture.runtime.fetchLatestOutput(in: fixture.thread.id, output: format)
                XCTAssertNil(stored)
                if previews == 2 { await gate.release() }
            case let .lifecycle(.messageCommitted(message)) where message.role == .assistant: sawMessage = true
            case let .outputCommitted(_, value):
                XCTAssertTrue(sawMessage)
                XCTAssertEqual(value.records.count, 2); committed += 1
                let stored = try await fixture.runtime.fetchLatestOutput(in: fixture.thread.id, output: format)
                XCTAssertEqual(stored?.records, value.records)
                let summary = try await fixture.runtime.fetchThreadSummary(id: fixture.thread.id)
                XCTAssertEqual(summary.latestTurnStatus, .completed)
            case .lifecycle(.turnCompleted): completed = true
            default: break
            }
        }
        XCTAssertEqual(previews, 2); XCTAssertEqual(committed, 1); XCTAssertTrue(completed)
    }

    func testSourceMismatchWrongIdentityReorderDuplicatesAndBackendFailureNeverCommit() async throws {
        for mode in OutputTestBackend.Mode.failureModes {
            let fixture = try await OutputRuntimeFixture(backend: OutputTestBackend(source: source, mode: mode))
            defer { fixture.cleanUp() }
            var commits = 0
            do {
                for try await event in try await fixture.runtime.stream(Request(text: "Go"), in: fixture.thread.id, output: format) {
                    if case .outputCommitted = event { commits += 1 }
                }
                XCTFail("Expected failure: \(mode)")
            } catch {}
            XCTAssertEqual(commits, 0)
            let stored = try await fixture.runtime.fetchLatestOutput(in: fixture.thread.id, output: format)
            XCTAssertNil(stored)
            let page = try await fixture.runtime.fetchThreadHistory(id: fixture.thread.id, query: .init(limit: 100))
            let messages = page.items.compactMap { if case let .message(message) = $0 { message } else { nil } }
            XCTAssertFalse(messages.contains { $0.role == .assistant && $0.phase != .commentary })
        }
    }

    func testUnclassifiedAndCompletionOnlyBackendFallback() async throws {
        for mode in [OutputTestBackend.Mode.unclassified, .completionOnly, .latePhase] {
            let fixture = try await OutputRuntimeFixture(backend: OutputTestBackend(source: source, mode: mode))
            defer { fixture.cleanUp() }
            let result = try await fixture.runtime.sendWithSummary(Request(text: "Go").correlated(with: "request-1"), in: fixture.thread.id, output: format)
            XCTAssertEqual(result.value.records.count, 2)
            XCTAssertEqual(result.clientRequestID, "request-1")
            XCTAssertEqual(result.memoryApplication, .notApplied(.notConfigured))
        }
    }

    func testFinalApplicationValidationCanRejectAllPreviews() async throws {
        let fixture = try await OutputRuntimeFixture(backend: OutputTestBackend(source: source))
        defer { fixture.cleanUp() }
        var format = format
        format.finalValidation = { _ in throw AgentOutputError.invalidOutput("Business constraint failed") }
        var previews = 0, failures = 0
        do {
            for try await event in try await fixture.runtime.stream(Request(text: "Go"), in: fixture.thread.id, output: format) {
                if case .format = event { previews += 1 }
                if case .validationFailed = event { failures += 1 }
                if case .outputCommitted = event { XCTFail("Invalid collection committed") }
            }
            XCTFail("Expected validation failure")
        } catch {}
        XCTAssertEqual(previews, 2); XCTAssertEqual(failures, 1)
        let stored = try await fixture.runtime.fetchLatestOutput(in: fixture.thread.id, output: format)
        XCTAssertNil(stored)
    }

    func testSteeringAfterPreviewIsRejectedWithoutCancellingTurn() async throws {
        let gate = ToolExecutionGate()
        let fixture = try await OutputRuntimeFixture(backend: OutputTestBackend(source: source, beforeCompletion: { await gate.wait() }))
        defer { fixture.cleanUp() }
        let execution = try await fixture.runtime.start(Request(text: "Go"), in: fixture.thread.id, output: format)
        var didCommit = false
        for try await event in execution.events {
            if case .format = event {
                do { try await execution.steer("Change"); XCTFail("Steering accepted") } catch is AgentOutputError {}
                await gate.release()
            }
            if case .outputCommitted = event { didCommit = true }
        }
        XCTAssertTrue(didCommit)
    }

    func testCancellationBeforeCompletionDoesNotPersistOutput() async throws {
        let gate = ToolExecutionGate()
        let fixture = try await OutputRuntimeFixture(backend: OutputTestBackend(source: source, beforeCompletion: { await gate.wait() }))
        defer { fixture.cleanUp() }
        let execution = try await fixture.runtime.start(Request(text: "Go"), in: fixture.thread.id, output: format)
        do {
            for try await event in execution.events {
                if case .format = event { execution.cancel(); await gate.release() }
                if case .outputCommitted = event { XCTFail("Cancelled output committed") }
            }
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        let stored = try await fixture.runtime.fetchLatestOutput(in: fixture.thread.id, output: format)
        XCTAssertNil(stored)
    }

    func testEphemeralAndConcurrentExecutionsHaveIsolatedDecoders() async throws {
        let format = format
        let fixture = try await OutputRuntimeFixture(backend: OutputTestBackend(source: source))
        defer { fixture.cleanUp() }
        async let first = fixture.runtime.send(Request(text: "One", executionMode: .ephemeral), in: fixture.thread.id, output: format)
        async let second = fixture.runtime.send(Request(text: "Two", executionMode: .ephemeral), in: fixture.thread.id, output: format)
        let values = try await [first, second]
        XCTAssertEqual(values.map { $0.records.count }, [2, 2])
        let metadata = try await fixture.runtime.fetchLatestStructuredOutputMetadata(id: fixture.thread.id)
        XCTAssertNil(metadata)
    }

    func testEnvelopesRestoreQueryReplayAndRedactAcrossAllStores() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let factories: [() throws -> any RuntimeStateStoring] = [
            { InMemoryRuntimeStateStore() },
            { FileRuntimeStateStore(url: directory.appendingPathComponent("output.json")) },
            { try SQLiteRuntimeStateStore(url: directory.appendingPathComponent("output.sqlite")) },
            { try RealmRuntimeStateStore(url: directory.appendingPathComponent("output.realm")) }
        ]
        for factory in factories {
            let store = try factory()
            let fixture = try await OutputRuntimeFixture(backend: OutputTestBackend(source: source), store: store)
            defer { fixture.cleanUp() }
            let result = try await fixture.runtime.send(Request(text: "Go"), in: fixture.thread.id, output: format)
            let state = try await store.loadState()
            let stored = try XCTUnwrap(state.messagesByThread[fixture.thread.id]?.last?.structuredOutput?.outputRepresentation)
            XCTAssertEqual(try stored.restore(using: format).records, result.records)
            XCTAssertEqual(stored.rawText, source)
            let query = try await fixture.runtime.execute(StructuredOutputQuery(threadIDs: [fixture.thread.id]))
            XCTAssertEqual(query.count, 1)
            let backend = OutputTestBackend(source: source)
            let restored = try await OutputRuntimeFixture(backend: backend, store: store, resumeID: fixture.thread.id)
            defer { restored.cleanUp() }
            let read = try await restored.runtime.fetchLatestOutput(in: fixture.thread.id, output: format)
            XCTAssertEqual(read?.records.first?.id, 9_007_199_254_740_993)
            _ = try await restored.runtime.send(Request(text: "Again"), in: fixture.thread.id, output: format)
            let replayed = await backend.historyContains(source)
            XCTAssertTrue(replayed)
            let history = try await restored.runtime.execute(HistoryItemsQuery(threadID: fixture.thread.id, kinds: [.message]))
            let ids = history.records.filter { if case let .message(message) = $0.item { message.role == .assistant } else { false } }.map(\.id)
            try await restored.runtime.redactHistoryItems(ids, in: fixture.thread.id)
            let latest = try await restored.runtime.fetchLatestOutput(in: fixture.thread.id, output: format)
            XCTAssertNil(latest)
        }
    }
}

struct OutputRuntimeFixture {
    let runtime: AgentRuntime
    let thread: AgentThread
    let secure = KeychainSessionSecureStore(service: "CodexKit.OutputTests", account: UUID().uuidString)
    init(backend: any AgentBackend, store: any RuntimeStateStoring = InMemoryRuntimeStateStore(), resumeID: String? = nil) async throws {
        runtime = try AgentRuntime(configuration: .init(authProvider: DemoChatGPTAuthProvider(), secureStore: secure,
            backend: backend, approvalPresenter: AutoApprovalPresenter(), stateStore: store, maximumBufferedEvents: 1))
        _ = try await runtime.useSession(demoSession())
        if let resumeID { thread = try await runtime.resumeThread(id: resumeID) }
        else { thread = try await runtime.createThread() }
    }
    func cleanUp() { try? secure.deleteSession() }
}

actor OutputTestBackend: AgentBackend {
    enum Mode: Sendable {
        case normal, mismatch, identity, reorder, duplicate, backendFailure, unclassified, completionOnly, latePhase, toolAfterOutput
        static let failureModes: [Self] = [.mismatch, .identity, .reorder, .duplicate, .backendFailure, .toolAfterOutput]
    }
    let source: String
    let mode: Mode
    let beforeCompletion: @Sendable () async -> Void
    var history: [String] = []
    init(source: String, mode: Mode = .normal, beforeCompletion: @escaping @Sendable () async -> Void = {}) {
        self.source = source; self.mode = mode; self.beforeCompletion = beforeCompletion
    }
    func historyContains(_ text: String) -> Bool { history.contains(text) }
    func createThread(session: ChatGPTSession) async throws -> AgentThread { .init(id: UUID().uuidString) }
    func resumeThread(id: String, session: ChatGPTSession) async throws -> AgentThread { .init(id: id) }
    func beginTurn(thread: AgentThread, history: [AgentMessage], message: Request, instructions: String,
                   responseFormat: AgentStructuredOutputFormat?, streamedStructuredOutput: AgentStreamedStructuredOutputRequest?,
                   tools: [ToolDefinition], session: ChatGPTSession) async throws -> AgentTurnStream {
        self.history = history.map(\.text)
        let answerID = history.contains(where: { $0.role == .assistant }) ? UUID().uuidString : "answer"
        let channel = AgentEventChannel<AgentBackendEvent>.makeStream(capacity: 1)
        let source = source, mode = mode, beforeCompletion = beforeCompletion
        let task = Task {
            do {
                let turn = AgentTurn(id: UUID().uuidString, threadID: thread.id)
                try await channel.continuation.yield(.turnStarted(turn))
                if mode != .completionOnly {
                    let parts = mode == .latePhase ? source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) : [source]
                    for (index, part) in parts.enumerated() {
                        let text = mode == .latePhase && index < parts.count - 1 ? part + "\n" : part
                        try await channel.continuation.yield(.assistantContentDelta(.init(threadID: thread.id, turnID: turn.id,
                            messageID: answerID, contentIndex: mode == .reorder ? 2 : 0,
                            phase: mode == .unclassified || (mode == .latePhase && index == 0) ? nil : .finalAnswer, text: text)))
                    }
                }
                await beforeCompletion()
                if mode == .backendFailure { throw AgentOutputError.invalidOutput("Injected provider failure") }
                if mode == .toolAfterOutput {
                    try await channel.continuation.yield(.toolCallRequested(.init(id: "call", threadID: thread.id, turnID: turn.id,
                        toolName: "never", arguments: .object([:]))))
                }
                let answer = AgentMessage(id: mode == .identity ? "wrong" : answerID, threadID: thread.id, role: .assistant,
                    text: mode == .mismatch ? source + " " : source, phase: .finalAnswer)
                try await channel.continuation.yield(.assistantMessageCompleted(answer))
                if mode == .duplicate { try await channel.continuation.yield(.assistantMessageCompleted(answer)) }
                try await channel.continuation.yield(.turnCompleted(.init(threadID: thread.id, turnID: turn.id)))
                channel.continuation.finish()
            } catch { channel.continuation.finish(throwing: error) }
        }
        channel.continuation.onCancellation { task.cancel() }
        return .init(events: channel.stream, steer: { _ in }, interrupt: { task.cancel() })
    }
}
