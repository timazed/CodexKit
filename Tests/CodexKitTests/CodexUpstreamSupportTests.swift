@testable import CodexKit
import XCTest

final class CodexUpstreamSupportTests: XCTestCase {
    override func setUp() async throws { await TestURLProtocol.reset() }
    override func tearDown() async throws { await TestURLProtocol.reset() }

    private func session(_ account: String = "test-account") -> ChatGPTSession {
        .init(accessToken: "test-token", refreshToken: "test-refresh",
              account: .init(id: account, email: "test@example.com", plan: .plus))
    }
    private func backend(attempts: Int = 1) -> CodexResponsesBackend {
        .init(configuration: .init(requestRetryPolicy: .init(maxAttempts: attempts,
            initialBackoff: 0, maxBackoff: 0, jitterFactor: 0)), urlSession: makeTestURLSession())
    }
    private func begin(_ backend: CodexResponsesBackend, tools: [ToolDefinition] = []) async throws -> AgentTurnStream {
        try await backend.beginTurn(thread: .init(id: "thread"), history: [], message: Request(text: "Hello"),
            instructions: "Help", responseFormat: nil, streamedStructuredOutput: nil, tools: tools, session: session())
    }
    private func enqueue(_ events: [String], headers: [String: String] = [:]) async {
        let body = events.map { "data: \($0)\n\n" }.joined()
        await TestURLProtocol.enqueue(.init(headers: headers, body: Data(body.utf8)))
    }
    private let completed = #"{"type":"response.completed","response":{"id":"r","usage":{"input_tokens":1,"output_tokens":1}}}"#

    func testUnknownProtocolValuesDoNotInterruptOrLoseProviderHistory() async throws {
        let opaqueItem = #"{"type":"future_item","id":"opaque","payload":{"keep":true}}"#
        await enqueue([
            #"{"type":"response.future_event","sequence_number":1}"#,
            "{\"type\":\"response.output_item.done\",\"item\":\(opaqueItem)}",
            #"{"type":"response.output_item.done","item":{"id":"m","type":"message","role":"assistant","content":[{"type":"future_content","text":"Answer"}]}}"#,
            completed
        ])
        let stream = try await begin(backend())
        var context: AgentProviderContext?
        var messages: [AgentMessage] = []
        var completions = 0
        for try await event in stream.events {
            switch event {
            case let .providerContextUpdated(_, value): context = value
            case let .assistantMessageCompleted(value): messages.append(value)
            case .turnCompleted: completions += 1
            default: break
            }
        }
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(messages.map(\.text), ["Answer"])
        let expected = try JSONDecoder().decode(JSONValue.self, from: Data(opaqueItem.utf8))
        XCTAssertTrue(context?.payload.objectValue?["items"]?.arrayValue?.contains(expected) == true)
    }

    func testPrematureEOFIsFailureAndRetriesOnlyBeforeCommittedOutput() async throws {
        await enqueue([])
        let first = try await begin(backend())
        do {
            for try await _ in first.events {}
            XCTFail("EOF must not complete a turn")
        } catch let error as AgentRuntimeError {
            XCTAssertEqual(error.code, "responses_stream_disconnected")
        }
        await enqueue([])
        await enqueue([completed])
        let retry = try await begin(backend(attempts: 2))
        var completions = 0
        for try await event in retry.events { if case .turnCompleted = event { completions += 1 } }
        XCTAssertEqual(completions, 1)

        await enqueue([#"{"type":"response.output_item.done","item":{"id":"m","type":"message","role":"assistant","content":[{"type":"output_text","text":"Partial"}]}}"#])
        let committed = try await begin(backend(attempts: 2))
        do {
            for try await _ in committed.events {}
            XCTFail("Committed partial output cannot be retried or completed")
        } catch let error as AgentRuntimeError {
            XCTAssertEqual(error.code, "responses_stream_disconnected")
        }
    }

    func testProgressPhaseAndLimitsRemainSeparateFromAnswerText() async throws {
        let backend = backend()
        await enqueue([
            #"{"type":"response.output_item.added","item":{"id":"m","type":"message","role":"assistant","phase":"commentary","content":[]}}"#,
            #"{"type":"response.reasoning_summary_text.delta","item_id":"reason","summary_index":0,"delta":"Checking options"}"#,
            #"{"type":"response.web_search_call.in_progress","item_id":"search"}"#,
            #"{"type":"response.web_search_call.searching","item_id":"search"}"#,
            #"{"type":"response.web_search_call.completed","item_id":"search"}"#,
            #"{"type":"response.output_item.done","item":{"id":"search","type":"web_search_call","status":"completed","action":{"type":"search","query":"options"}}}"#,
            #"{"type":"codex.rate_limits","metered_limit_name":"codex-other","rate_limits":{"primary":{"used_percent":30,"window_minutes":300,"reset_at":123456}}}"#,
            #"{"type":"response.output_item.done","item":{"id":"m","type":"message","role":"assistant","phase":"final_answer","content":[{"type":"output_text","text":"Answer"}]}}"#,
            completed
        ], headers: ["x-codex-primary-used-percent": "20", "x-codex-primary-window-minutes": "300"])
        let stream = try await begin(backend)
        var progress: [AgentProgress] = []
        var messages: [AgentMessage] = []
        var limits: [AgentRateLimitSnapshot] = []
        for try await event in stream.events {
            switch event {
            case let .progress(value): progress.append(value.content)
            case let .assistantMessageCompleted(value): messages.append(value)
            case let .rateLimitsUpdated(value): limits.append(contentsOf: value)
            default: break
            }
        }
        XCTAssertTrue(progress.contains(.reasoningSummaryDelta(itemID: "reason", summaryIndex: 0, delta: "Checking options")))
        XCTAssertTrue(progress.contains(.messageStarted(itemID: "m", phase: .commentary)))
        for status in ["in_progress", "searching", "completed"] {
            XCTAssertTrue(progress.contains(.webSearch(itemID: "search", status: status, action: nil)))
        }
        XCTAssertEqual(messages.map(\.text), ["Answer"])
        XCTAssertEqual(messages.first?.phase, .finalAnswer)
        let restored = try JSONDecoder().decode(AgentMessage.self, from: JSONEncoder().encode(messages[0]))
        XCTAssertEqual(restored.phase, .finalAnswer)
        XCTAssertEqual(limits.map(\.limitID), ["codex", "codex_other"])
        let cached = await backend.rateLimits(session: session())
        XCTAssertEqual(cached.count, 2)
        XCTAssertEqual(cached.first?.primary?.remainingPercent, 80)
        let other = await backend.rateLimits(session: session("other"))
        XCTAssertTrue(other.isEmpty)
    }

    func testModelDiscoveryCachesRevalidatesAndSeparatesAccounts() async throws {
        let backend = backend()
        let catalog = #"{"models":[{"slug":"future","display_name":"Future","description":"New","default_reasoning_level":"high","supported_reasoning_levels":[{"effort":"high"},{"effort":"future_effort"}],"input_modalities":["text"],"context_window":500000,"visibility":"list","supports_parallel_tool_calls":true}]}"#
        await TestURLProtocol.enqueue(.init(headers: ["ETag": "v1"], body: Data(catalog.utf8), inspect: { request in
            XCTAssertEqual(request.url?.path, "/backend-api/codex/models")
            XCTAssertTrue(request.url?.query?.contains("client_version=") == true)
        }))
        let remote = try await backend.listModels(session: session())
        XCTAssertEqual(remote.visibleModels.first?.model.rawValue, "future")
        XCTAssertEqual(remote.visibleModels.first?.supportedReasoningEfforts, [.high, .custom("future_effort")])
        let cached = try await backend.listModels(session: session())
        if case .cache = cached.source {} else { XCTFail("Expected cache") }
        let window = await backend.modelContextWindowTokenCount(for: "future")
        XCTAssertEqual(window, 500000)
        await TestURLProtocol.enqueue(.init(statusCode: 304, body: Data(), inspect: { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "v1")
        }))
        let refreshed = try await backend.listModels(session: session(), policy: .refresh)
        XCTAssertFalse(refreshed.isStale)
        let other = try await backend.listModels(session: session("other"), policy: .cachedOnly)
        if case .bundled = other.source {} else { XCTFail("Account caches must be separate") }
        XCTAssertTrue(other.visibleModels.contains { $0.model == .gpt6Astra })
    }

    func testCatalogFailureFallsBackButExplicitRefreshThrowsAnd429RetainsLimits() async throws {
        let backend = backend()
        await TestURLProtocol.enqueue(.init(statusCode: 503, body: Data()))
        let fallback = try await backend.listModels(session: session())
        if case .bundled = fallback.source {} else { XCTFail("Expected bundled fallback") }
        await TestURLProtocol.enqueue(.init(statusCode: 429, headers: ["x-codex-primary-used-percent": "100"], body: Data()))
        do {
            _ = try await backend.listModels(session: session(), policy: .refresh)
            XCTFail("Forced refresh must report failures")
        } catch {}
        let limits = await backend.rateLimits(session: session())
        XCTAssertEqual(limits.first?.primary?.remainingPercent, 0)
    }

    func testCatalogDistinguishesMissingListsFromExplicitListsAndPreservesFutureEfforts() throws {
        let data = Data(#"{"models":[{"slug":"gpt-6-astra"},{"slug":"empty","supported_reasoning_levels":[],"input_modalities":[]},{"slug":"mixed","default_reasoning_level":"future_effort","supported_reasoning_levels":[{"effort":"high"},{"effort":"future_effort"},{"effort":42},null],"input_modalities":["text","future_modality",42]}]}"#.utf8)
        let catalog = try CodexResponsesBackend.decodeModels(data)
        XCTAssertEqual(catalog.count, 3)
        let missing = try XCTUnwrap(catalog.first)
        XCTAssertEqual(missing.supportedReasoningEfforts, CodexModel.gpt6Astra.info?.supportedReasoningEfforts)
        XCTAssertEqual(missing.inputModalities, [.text, .image])
        XCTAssertEqual(missing.defaultReasoningEffort, .medium)
        let empty = try XCTUnwrap(catalog.first { $0.model.rawValue == "empty" })
        XCTAssertTrue(empty.supportedReasoningEfforts.isEmpty)
        XCTAssertTrue(empty.inputModalities.isEmpty)
        let mixed = try XCTUnwrap(catalog.first { $0.model.rawValue == "mixed" })
        XCTAssertEqual(mixed.supportedReasoningEfforts, [.high, .custom("future_effort")])
        XCTAssertEqual(mixed.defaultReasoningEffort, .custom("future_effort"))
        XCTAssertEqual(mixed.inputModalities, [.text])
    }

    func testAstraMetadataAndUnknownPhaseRoundTrip() throws {
        let astra = try XCTUnwrap(CodexModel.gpt6Astra.info)
        XCTAssertEqual(astra.model.rawValue, "gpt-6-astra")
        XCTAssertEqual(astra.defaultReasoningEffort, .low)
        XCTAssertEqual(astra.supportedReasoningEfforts, [.low, .medium, .high, .extraHigh, .max, .ultra])
        XCTAssertEqual(astra.contextWindowTokenCount, 272000)
        let phase = try JSONDecoder().decode(AgentMessagePhase.self, from: Data(#""future""#.utf8))
        XCTAssertEqual(phase.rawValue, "future")
    }
}
