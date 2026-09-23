@testable import CodexKit
import XCTest

final class AgentOutputCommitTests: XCTestCase {
    func testCancellationDuringCommitReportsActualStorageOutcome() async throws {
        for fails in [false, true] {
            let store = OutputTransactionStore(fails: fails)
            let runtime = try AgentRuntime(configuration: .init(sessionProvider: DesignReadOnlyProvider(),
                backend: OutputTestBackend(source: "{\"id\":1,\"text\":\"done\"}\n"),
                approvalPresenter: AutoApprovalPresenter(), stateStore: store))
            let thread = try await runtime.createThread()
            let format = AgentRecordResponseFormat(name: "records", record: AgentOutputDecoderTests.Record.self)
            let execution = try await runtime.start(Request(text: "Go"), in: thread.id, output: format)
            let consumer = Task {
                var committed = false
                do {
                    for try await event in execution.events {
                        if case .outputCommitted = event { committed = true }
                    }
                    return (committed, false)
                } catch OutputStoreFailure.injected { return (committed, true) }
            }
            await store.entered.wait()
            execution.cancel()
            await store.release.release()
            let result = try await consumer.value
            XCTAssertEqual(result.0, !fails)
            XCTAssertEqual(result.1, fails)
            let saved = try await runtime.fetchLatestOutput(in: thread.id, output: format)
            XCTAssertEqual(saved != nil, !fails)
            let state = try await store.loadState()
            XCTAssertEqual(state.messagesByThread[thread.id]?.contains(where: { $0.role == .assistant }), !fails)
            let hasCompletion = state.historyByThread[thread.id, default: []].contains {
                if case let .systemEvent(event) = $0.item { event.type == .turnCompleted } else { false }
            }
            XCTAssertEqual(hasCompletion, !fails)
        }
    }

    func testCustomDecoderUsesSameStreamingAndPersistenceContract() async throws {
        let runtime = try AgentRuntime(configuration: .init(sessionProvider: DesignReadOnlyProvider(),
            backend: OutputTestBackend(source: "hello"), approvalPresenter: AutoApprovalPresenter(), stateStore: InMemoryRuntimeStateStore()))
        let thread = try await runtime.createThread()
        let output = try await runtime.send(Request(text: "Go"), in: thread.id, output: UppercaseOutputFormat(persist: true))
        XCTAssertEqual(output, "HELLO")
        let stored = try await runtime.fetchLatestOutput(in: thread.id, output: UppercaseOutputFormat(persist: true))
        XCTAssertEqual(stored, "HELLO")
        do {
            _ = try await runtime.start(Request(text: "Go"), in: thread.id, output: UppercaseOutputFormat(persist: false))
            XCTFail("Missing persistence adapter accepted for stored execution")
        } catch AgentOutputError.persistenceUnavailable {}
        let ephemeral = try await runtime.send(Request(text: "Go", executionMode: .ephemeral), in: thread.id, output: UppercaseOutputFormat(persist: false))
        XCTAssertEqual(ephemeral, "HELLO")
    }

    func testInvalidXMLSchemaFailsBeforeRequestIsPersisted() async throws {
        let store = InMemoryRuntimeStateStore()
        let runtime = try AgentRuntime(configuration: .init(sessionProvider: DesignReadOnlyProvider(),
            backend: OutputTestBackend(source: "never"), approvalPresenter: AutoApprovalPresenter(), stateStore: store))
        let thread = try await runtime.createThread()
        let before = try await store.loadState()
        do {
            _ = try await runtime.start(Request(text: "Go"), in: thread.id, output: AgentXMLResponseFormat(name: "bad",
                schema: .xsd("<invalid/>", root: "r")))
            XCTFail("Invalid schema accepted")
        } catch {}
        let after = try await store.loadState()
        XCTAssertEqual(before, after)
    }
}

private enum OutputStoreFailure: Error { case injected }
private actor OutputTransactionStore: RuntimeStateStoring {
    let base = InMemoryRuntimeStateStore()
    let entered = ToolExecutionGate()
    let release = ToolExecutionGate()
    let fails: Bool
    init(fails: Bool) { self.fails = fails }
    func loadState() async throws -> StoredRuntimeState { try await base.loadState() }
    func saveState(_ state: StoredRuntimeState) async throws { try await base.saveState(state) }
    func apply(_ operations: [AgentStoreWriteOperation]) async throws {
        let isFinal = operations.contains { operation in
            guard case let .appendHistoryItems(_, records) = operation else { return false }
            return records.contains { if case let .message(message) = $0.item { message.structuredOutput?.outputRepresentation != nil } else { false } }
        }
        if isFinal {
            try RuntimeStoreCommitScope.begin()
            await entered.release()
            await release.wait()
            if fails { throw OutputStoreFailure.injected }
        }
        try await base.apply(operations)
    }
}

private struct UppercaseOutputFormat: AgentOutputFormat {
    let persist: Bool
    let name = "uppercase"
    let codecIdentifier = "test.uppercase"
    let limits = AgentStructuredOutputLimits()
    let formatInstructions = "Return plain text."
    var persistence: AgentOutputPersistence<String>? { persist ? .json : nil }
    func makeDecoder() -> UppercaseDecoder { .init() }
}
private actor UppercaseDecoder: AgentOutputDecoder {
    typealias Event = String
    typealias Output = String
    var text = ""
    func consume(_ bytes: Data, into sink: AgentOutputEventSink<String>) async throws {
        let fragment = String(decoding: bytes, as: UTF8.self).uppercased()
        text += fragment
        try await sink.emit(fragment, encodedByteCount: fragment.utf8.count)
    }
    func finish(into sink: AgentOutputEventSink<String>) -> String { text }
}
