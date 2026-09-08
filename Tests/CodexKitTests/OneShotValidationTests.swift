@testable import CodexKit
import CodexKitRealm
import CodexKitSQLite
import XCTest

final class OneShotValidationTests: XCTestCase {
    func testSchemaFailuresNeverCommitAnAssistantReplyOrSuccessfulTurn() async throws {
        for summary in [false, true] {
            for text in [#"{"priority":"impossible"}"#, "{}", #"{"priority":"low","extra":1}"#] {
                let store = InMemoryRuntimeStateStore()
                let runtime = try runtime(text: text, store: store)
                let thread = try await runtime.createThread()
                do {
                    if summary { _ = try await runtime.sendWithSummary(Request(text: "Go"), in: thread.id, response: PriorityOutput.self) }
                    else { _ = try await runtime.send(Request(text: "Go"), in: thread.id, response: PriorityOutput.self) }
                    XCTFail("Expected schema failure")
                } catch { XCTAssertEqual((error as? AgentRuntimeError)?.code, "structured_output_schema_invalid") }
                try await assertFailed(store, threadID: thread.id)
            }
        }
    }

    func testSwiftDecodeFailuresAreRecordedBeforeReopeningEitherDatabase() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        for adapter in ["sqlite", "realm"] {
            let url = directory.appendingPathComponent(adapter)
            let open: () throws -> any RuntimeStateStoring = {
                adapter == "sqlite" ? try SQLiteRuntimeStateStore(url: url) : try RealmRuntimeStateStore(url: url)
            }
            for summary in [false, true] {
                let runtime = try runtime(text: #"{"priority":"low"}"#, store: open())
                let thread = try await runtime.createThread()
                do {
                    if summary { _ = try await runtime.sendWithSummary(Request(text: "Go"), in: thread.id, response: MismatchedOutput.self) }
                    else { _ = try await runtime.send(Request(text: "Go"), in: thread.id, response: MismatchedOutput.self) }
                    XCTFail("Expected decoding failure")
                } catch { XCTAssertEqual((error as? AgentRuntimeError)?.code, "structured_output_decoding_failed") }
                try await assertFailed(open(), threadID: thread.id)
            }
        }
    }

    func testValidOneShotAllowsCommentaryAndReturnsDecodedValue() async throws {
        let runtime = try runtime(text: #"{"priority":"high"}"#, commentary: true)
        let thread = try await runtime.createThread()
        let result = try await runtime.send(Request(text: "Go"), in: thread.id, response: PriorityOutput.self)
        XCTAssertEqual(result.priority, "high")
        let summary = try await runtime.sendWithSummary(Request(text: "Again"), in: thread.id, response: PriorityOutput.self)
        XCTAssertEqual(summary.value.priority, "high")
        let messages = await runtime.messages(for: thread.id)
        XCTAssertEqual(messages.filter { $0.phase == .commentary }.count, 2)
    }

    func testCustomDecoderRunsOnceAndPreservesLargeIntegerPrecision() async throws {
        let runtime = try runtime(text: #"{"value":9007199254740993}"#)
        let thread = try await runtime.createThread()
        let decoder = JSONDecoder()
        decoder.userInfo[SingleDecodeOutput.counterKey] = DecodeCounter()
        let result = try await runtime.send(Request(text: "Go"), in: thread.id, response: SingleDecodeOutput.self, decoder: decoder)
        XCTAssertEqual(result.value, 9_007_199_254_740_993)
        XCTAssertEqual(result.decodeCount, 1)
    }

    func testUnsupportedRawSchemaFailsBeforeStartingOrPersisting() async throws {
        let store = InMemoryRuntimeStateStore()
        let runtime = try runtime(text: #"{"priority":"low"}"#, store: store)
        let thread = try await runtime.createThread()
        let before = try await store.loadState()
        do {
            _ = try await runtime.send(Request(text: "Go"), in: thread.id, response: UnsupportedOutput.self)
            XCTFail("Expected unsupported schema")
        } catch { XCTAssertEqual((error as? AgentRuntimeError)?.code, "unsupported_schema_keyword") }
        let after = try await store.loadState()
        XCTAssertEqual(after, before)
    }

    func testCommentaryAloneCannotCompleteAOneShotResponse() async throws {
        let store = InMemoryRuntimeStateStore()
        let runtime = try runtime(text: nil, commentary: true, store: store)
        let thread = try await runtime.createThread()
        do {
            _ = try await runtime.send(Request(text: "Go"), in: thread.id, response: PriorityOutput.self)
            XCTFail("Expected missing output")
        } catch { XCTAssertEqual((error as? AgentRuntimeError)?.code, "structured_output_missing") }
        let state = try await store.loadState()
        XCTAssertEqual(state.threads.first?.status, .failed)
    }

    private func runtime(text: String?, commentary: Bool = false,
        store: any RuntimeStateStoring = InMemoryRuntimeStateStore()) throws -> AgentRuntime {
        try .init(configuration: .init(sessionProvider: DesignReadOnlyProvider(),
            backend: OneShotBackend(text: text, commentary: commentary),
            approvalPresenter: AutoApprovalPresenter(), stateStore: store))
    }

    private func assertFailed(_ store: any RuntimeStateStoring, threadID: String) async throws {
        let state = try await store.loadState()
        XCTAssertEqual(state.messagesByThread[threadID]?.map(\.role), [.user])
        XCTAssertEqual(state.threads.first { $0.id == threadID }?.status, .failed)
        XCTAssertEqual(state.summariesByThread[threadID]?.latestTurnStatus, .failed)
        XCTAssertFalse((state.historyByThread[threadID] ?? []).contains {
            if case let .systemEvent(event) = $0.item { return event.type == .turnCompleted }
            return false
        })
    }
}

private struct PriorityOutput: AgentStructuredOutput {
    let priority: String
    static let responseFormat = AgentStructuredOutputFormat(name: "priority",
        schema: .object(properties: ["priority": .string(enum: ["low", "high"])], required: ["priority"]))
}

private struct MismatchedOutput: AgentStructuredOutput {
    let priority: Int
    static let responseFormat = PriorityOutput.responseFormat
}

private struct UnsupportedOutput: AgentStructuredOutput {
    let priority: String
    static let responseFormat = AgentStructuredOutputFormat(name: "unsupported",
        schema: .raw(.object(["pattern": .string(".*")])))
}

private struct SingleDecodeOutput: AgentStructuredOutput {
    let value: Int64
    let decodeCount: Int
    static let responseFormat = AgentStructuredOutputFormat(name: "integer",
        schema: .object(properties: ["value": .integer], required: ["value"]))
    static let counterKey = CodingUserInfoKey(rawValue: "decodeCounter")!
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        value = try container.decode(Int64.self, forKey: .value)
        decodeCount = (decoder.userInfo[Self.counterKey] as? DecodeCounter)?.next() ?? 0
    }
    private enum Key: CodingKey { case value }
}

private final class DecodeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.withLock { count += 1; return count } }
}

private struct OneShotBackend: AgentBackend {
    let text: String?
    let commentary: Bool
    func createThread(session: ChatGPTSession) async throws -> AgentThread { .init(id: UUID().uuidString) }
    func resumeThread(id: String, session: ChatGPTSession) async throws -> AgentThread { .init(id: id) }
    func beginTurn(thread: AgentThread, history: [AgentMessage], message: Request, instructions: String,
        responseFormat: AgentStructuredOutputFormat?, streamedStructuredOutput: AgentStreamedStructuredOutputRequest?,
        tools: [ToolDefinition], session: ChatGPTSession) async throws -> AgentTurnStream {
        let turn = AgentTurn(id: UUID().uuidString, threadID: thread.id)
        return .init(events: AsyncThrowingStream { continuation in
            continuation.yield(.turnStarted(turn))
            if commentary {
                continuation.yield(.assistantMessageCompleted(.init(threadID: thread.id, role: .assistant,
                    text: "Checking the details", phase: .commentary)))
            }
            if let text { continuation.yield(.assistantMessageCompleted(.init(threadID: thread.id, role: .assistant, text: text))) }
            continuation.yield(.turnCompleted(.init(threadID: thread.id, turnID: turn.id)))
            continuation.finish()
        })
    }
}
