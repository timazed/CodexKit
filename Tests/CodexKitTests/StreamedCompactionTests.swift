@testable import CodexKit
import XCTest

final class StreamedCompactionTests: XCTestCase {
    override func setUp() async throws { await TestURLProtocol.reset() }
    override func tearDown() async throws { await TestURLProtocol.reset() }

    func testRequestAndRetainedHistoryUseStreamedCompactionProtocol() async throws {
        let backend = CodexResponsesBackend(configuration: .init(extraHeaders: ["x-codex-beta-features": "existing"]),
            urlSession: makeTestURLSession())
        let history = [AgentMessage(threadID: "thread", role: .user, text: "Keep my question"),
            AgentMessage(threadID: "thread", role: .assistant, text: "Old answer")]
        await TestURLProtocol.enqueue(.init(body: streamedCompactionReply(additionalOutput: [
            .object(["type": .string("function_call"), "name": .string("unexpected"),
                "arguments": .string("{}"), "call_id": .string("call")])
        ]), inspect: { request in
            XCTAssertEqual(request.url?.path, "/backend-api/codex/responses")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-codex-beta-features"), "existing,remote_compaction_v2")
            let body = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(requestBodyData(for: request)))
            XCTAssertEqual(body.objectValue?["stream"], .bool(true))
            XCTAssertEqual(body.objectValue?["store"], .bool(false))
            XCTAssertNil(body.objectValue?["previous_response_id"])
            XCTAssertEqual(body.objectValue?["input"]?.arrayValue?.last, .object(["type": .string("compaction_trigger")]))
        }))
        let result = try await backend.compactContext(thread: .init(id: "thread"), effectiveHistory: history,
            instructions: "Instructions", tools: [], session: demoSession())
        XCTAssertEqual(result.effectiveMessages.map(\.text), ["Keep my question"])
        XCTAssertNil(result.summaryPreview)
        let items = try XCTUnwrap(result.providerContext?.payload.objectValue?["items"]?.arrayValue)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.last?.objectValue?["type"], .string("compaction"))
    }

    func testMissingDuplicateEmptyFailedAndIncompleteOutputsAreRejected() async throws {
        let done = "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"done\"}}\n\n"
        let item = "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"compaction\",\"encrypted_content\":\"opaque\"}}\n\n"
        let cases: [(String, String)] = [
            (done, "responses_compact_invalid_output"),
            (item + item + done, "responses_compact_invalid_output"),
            (item.replacingOccurrences(of: "opaque", with: "") + done, "responses_compact_invalid_output"),
            (item, "responses_stream_disconnected"),
            (item + "data: {\"type\":\"response.failed\"}\n\n", "responses_stream_failed"),
            (item + "data: {\"type\":\"response.incomplete\"}\n\n", "responses_stream_incomplete")
        ]
        for (body, expected) in cases {
            await TestURLProtocol.enqueue(.init(body: Data(body.utf8)))
            do {
                _ = try await compact()
                XCTFail("Expected \(expected)")
            } catch { XCTAssertEqual((error as? AgentRuntimeError)?.code, expected) }
        }
    }

    func testInterruptedStreamRetriesWithoutKeepingPartialCheckpoint() async throws {
        await TestURLProtocol.enqueue(.init(body: Data("data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"compaction\",\"encrypted_content\":\"partial\"}}\n\n".utf8)))
        await TestURLProtocol.enqueue(.init(body: streamedCompactionReply(encryptedContent: "complete")))
        let result = try await compact(policy: .init(maxAttempts: 2, initialBackoff: 0, maxBackoff: 0))
        XCTAssertEqual(result.providerContext?.payload.objectValue?["items"]?.arrayValue?.last?.objectValue?["encrypted_content"], .string("complete"))
    }

    func testQuotaFailureDoesNotRetryCompaction() async throws {
        await TestURLProtocol.enqueue(.init(statusCode: 429, body: Data(#"{"error":{"code":"insufficient_quota"}}"#.utf8)))
        await TestURLProtocol.enqueue(.init(body: streamedCompactionReply(), inspect: { _ in XCTFail("Quota must not retry") }))
        do { _ = try await compact(policy: .default); XCTFail("Expected quota") }
        catch { XCTAssertEqual((error as? AgentRuntimeError)?.code, "quota_exceeded") }
    }

    func testRetentionBoundsKeepRecentInputAndDoNotAlterOriginalHistory() throws {
        let old = WorkingHistoryItem.visibleMessage(AgentMessage(threadID: "thread", role: .user,
            text: String(repeating: "🐈", count: 100_000))).jsonValue
        let recent = WorkingHistoryItem.visibleMessage(AgentMessage(threadID: "thread", role: .user, text: "Recent")).jsonValue
        let result = try CodexResponsesCompactedHistory.build(input: [old, recent],
            compaction: .object(["type": .string("compaction"), "encrypted_content": .string("opaque")]), threadID: "thread")
        XCTAssertEqual(result.effectiveMessages.last?.text, "Recent")
        XCTAssertLessThanOrEqual(result.effectiveMessages.reduce(0) { $0 + $1.text.utf8.count }, 256_000)
        XCTAssertFalse(result.effectiveMessages.first?.text.contains("�") ?? true)
        XCTAssertEqual(old.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue?.count, 100_000)
    }

    private func compact(policy: RequestRetryPolicy = .disabled) async throws -> AgentCompactionResult {
        try await CodexResponsesBackend(configuration: .init(requestRetryPolicy: policy), urlSession: makeTestURLSession())
            .compactContext(thread: .init(id: "thread"), effectiveHistory: [], instructions: "", tools: [], session: demoSession())
    }
}
