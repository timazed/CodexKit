@testable import CodexKit
import XCTest

final class UsageTelemetryTests: XCTestCase {
    private let capture = UsageRequestCapture()
    private let session = ChatGPTSession(accessToken: "SECRET_TOKEN", refreshToken: "SECRET_REFRESH",
        account: ChatGPTAccount(id: "PRIVATE_ACCOUNT", email: "PRIVATE_EMAIL", plan: .plus))
    private let message = "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"PRIVATE_OUTPUT\"}]}}\n\n"

    private func completion(_ usage: String?, id: String = "response-1") -> String {
        "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"\(id)\"\(usage.map { ",\"usage\":" + $0 } ?? "")}}\n\n"
    }

    private func run(_ body: String, logging: AgentLoggingConfiguration = .disabled,
                     retries: Int = 1) async throws -> (AgentTurnSummary, String) {
        let capture = capture
        await TestURLProtocol.enqueue(.init(headers: ["Content-Type": "text/event-stream"], body: Data(body.utf8),
            inspect: { capture.append(try XCTUnwrap(requestBodyData(for: $0))) }))
        let backend = CodexResponsesBackend(configuration: .init(
            requestRetryPolicy: .init(maxAttempts: retries, initialBackoff: 0, maxBackoff: 0), logging: logging),
            urlSession: makeTestURLSession())
        await backend.useDeterministicUsageTestEncoder()
        let stream = try await backend.beginTurn(thread: .init(id: "thread-usage"), history: [],
            message: Request(text: "PRIVATE_PROMPT"), instructions: "PRIVATE_INSTRUCTIONS", responseFormat: nil,
            streamedStructuredOutput: nil, tools: [], session: session)
        var summary: AgentTurnSummary?
        var text = ""
        for try await event in stream.events {
            if case let .turnCompleted(value) = event { summary = value }
            if case let .assistantMessageCompleted(value) = event { text += value.text }
        }
        return (try XCTUnwrap(summary), text)
    }

    func testFullMissingZeroAndMalformedUsageDeliverOutputOnceAndSafeInfoLogs() async throws {
        for usage in [AgentUsageTests.full, nil, "{}", "false",
                      #"{"input_tokens":0,"output_tokens":0}"#,
                      #"{"input_tokens":12,"output_tokens":4,"output_tokens_details":{"reasoning_tokens":"PRIVATE_REASONING"}}"#] {
            await TestURLProtocol.reset()
            capture.reset()
            let sink = UsageLogSink()
            let (summary, output) = try await run(message + completion(usage), logging: .init(minimumLevel: .info, sink: sink))
            XCTAssertEqual(output, "PRIVATE_OUTPUT")
            XCTAssertEqual(summary.usageObservations?.count, 1)
            let entries = sink.entries.filter { $0.metadata["event"] == "usage.response.observed" }
            XCTAssertEqual(entries.count, 1)
            let entry = try XCTUnwrap(entries.first)
            XCTAssertEqual(entry.metadata["usage_id"], "response:response-1")
            XCTAssertEqual(entry.metadata["usage_scope"], "response")
            XCTAssertEqual(entry.metadata["usage_reused"], "false")
            XCTAssertFalse(entries.description.contains("PRIVATE"))
            XCTAssertFalse(entries.description.contains("SECRET"))
            XCTAssertEqual(entry.metadata["input_tokens_availability"], summary.usage?.availability(of: .inputTokens).rawValue)
            let requests = capture.bodies
            XCTAssertEqual(requests.count, 1)
        }
    }

    func testDuplicateTerminalAndReplayedObservationHaveOneContribution() async throws {
        await TestURLProtocol.reset()
        capture.reset()
        let (summary, _) = try await run(message + completion(AgentUsageTests.full) + completion(AgentUsageTests.full))
        XCTAssertEqual(summary.usage?.inputTokens, 100)
        let observation = try XCTUnwrap(summary.usageObservations?.first)
        var accumulator = AgentUsageAccumulator()
        XCTAssertTrue(accumulator.insert(observation))
        XCTAssertFalse(accumulator.insert(observation.reused))
        XCTAssertEqual(accumulator.usage.inputTokens, 100)
        XCTAssertEqual(accumulator.usage.coverage?.responseCount, 1)
    }

    func testDisconnectFollowedByRetryPreservesUnknownCoverageAndDistinctAttempts() async throws {
        await TestURLProtocol.reset()
        capture.reset()
        let capture = capture
        await TestURLProtocol.enqueue(.init(headers: ["Content-Type": "text/event-stream"], body: Data(),
            inspect: { capture.append(try XCTUnwrap(requestBodyData(for: $0))) }))
        let sink = UsageLogSink()
        let (summary, _) = try await run(message + completion(AgentUsageTests.full),
            logging: .init(minimumLevel: .info, sink: sink), retries: 2)
        XCTAssertEqual(summary.usage?.inputTokens, 100)
        XCTAssertEqual(summary.usage?.coverage?.responseCount, 2)
        XCTAssertEqual(summary.usage?.availability(of: .inputTokens), .partial)
        let observations = try XCTUnwrap(summary.usageObservations)
        XCTAssertEqual(observations.map(\.outcome), [.unknown, .completed])
        XCTAssertEqual(Set(observations.map(\.attemptID)).count, 2)
        XCTAssertEqual(Set(observations.map(\.requestID)).count, 1)
        let requests = capture.bodies
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0], requests[1])
    }

    func testTerminalReplayUpgradesUnknownUsageWithoutAddingResponse() async throws {
        await TestURLProtocol.reset()
        let (summary, _) = try await run(message + completion(AgentUsageTests.full))
        let terminal = try XCTUnwrap(summary.usageObservations?.first)
        let unknown = AgentUsageObservation(id: terminal.id, threadID: terminal.threadID, turnID: terminal.turnID,
            requestID: terminal.requestID, passNumber: terminal.passNumber, attemptID: "earlier-attempt",
            responseID: terminal.responseID, operationID: nil, rootOperationID: nil,
            model: terminal.model, reasoningEffort: terminal.reasoningEffort, outcome: .unknown, usage: .unavailable())
        var accumulator = AgentUsageAccumulator()
        accumulator.insert(unknown)
        XCTAssertTrue(accumulator.insert(terminal))
        XCTAssertFalse(accumulator.insert(terminal.reused))
        XCTAssertEqual(accumulator.usage.inputTokens, 100)
        XCTAssertEqual(accumulator.usage.coverage?.responseCount, 1)
        XCTAssertEqual(accumulator.usage.availability(of: .inputTokens), .complete)
    }

    func testFailedAndIncompleteTerminalResponsesKeepUsageWithoutSuccess() async throws {
        for type in ["failed", "incomplete"] {
            await TestURLProtocol.reset()
            capture.reset()
            let sink = UsageLogSink()
            do {
                _ = try await run("data: {\"type\":\"response.\(type)\",\"response\":{\"id\":\"failed-id\",\"usage\":\(AgentUsageTests.full)}}\n\n",
                    logging: .init(minimumLevel: .info, sink: sink))
                XCTFail("Failure must not become successful content")
            } catch {}
            let entry = try XCTUnwrap(sink.entries.first { $0.metadata["event"] == "usage.response.observed" })
            XCTAssertEqual(entry.metadata["outcome"], type)
            XCTAssertEqual(entry.metadata["input_tokens"], "100")
            XCTAssertEqual(entry.metadata["codex_rollout_budget_units"], "2.5")
        }
    }

    func testToolPassesSumUsageWithPartialDetailCoverage() async throws {
        await TestURLProtocol.reset()
        let tool = ToolDefinition(name: "lookup", description: "Fixture", inputSchema: .object([
            "type": .string("object"), "properties": .object([:])]), approvalPolicy: .automatic)
        let first = "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"function_call\",\"name\":\"lookup\",\"arguments\":\"{}\",\"call_id\":\"call-1\"}}\n\n"
        await TestURLProtocol.enqueue(.init(headers: ["Content-Type": "text/event-stream"],
            body: Data((first + completion(AgentUsageTests.full)).utf8)))
        await TestURLProtocol.enqueue(.init(headers: ["Content-Type": "text/event-stream"],
            body: Data((message + completion(#"{"input_tokens":20,"output_tokens":3,"total_tokens":23}"#, id: "response-2")).utf8)))
        let backend = CodexResponsesBackend(urlSession: makeTestURLSession())
        let stream = try await backend.beginTurn(thread: .init(id: "thread-usage"), history: [],
            message: Request(text: "Lookup"), instructions: "Fixture", responseFormat: nil,
            streamedStructuredOutput: nil, tools: [tool], session: session)
        var summary: AgentTurnSummary?
        for try await event in stream.events {
            if case let .toolRoundRequested(round) = event {
                let invocation = try XCTUnwrap(round.calls.first)
                try await stream.submitToolResult(.success(invocation: invocation, text: "done"), for: invocation.id)
            }
            if case let .turnCompleted(value) = event { summary = value }
        }
        XCTAssertEqual(summary?.usage?.inputTokens, 120)
        XCTAssertEqual(summary?.usage?.outputTokens, 13)
        XCTAssertEqual(summary?.usage?.totalTokens, 133)
        XCTAssertEqual(summary?.usage?.reasoningOutputTokens, 5)
        XCTAssertEqual(summary?.usage?.availability(of: .reasoningOutputTokens), .partial)
        XCTAssertEqual(summary?.usage?.availability(of: .inputTokens), .complete)
        XCTAssertEqual(summary?.usageObservations?.map(\.passNumber), [1, 2])
        XCTAssertEqual(Set(summary?.usageObservations?.map(\.requestID) ?? []).count, 2)
    }

    func testLoggingDoesNotChangePreparedBytesOrContent() async throws {
        var requests: [Data] = []
        for logging in [AgentLoggingConfiguration.disabled, .init(minimumLevel: .info, sink: UsageLogSink())] {
            await TestURLProtocol.reset()
            capture.reset()
            let (_, output) = try await run(message + completion(AgentUsageTests.full), logging: logging)
            XCTAssertEqual(output, "PRIVATE_OUTPUT")
            let captured = capture.bodies
            requests.append(try XCTUnwrap(captured.first))
        }
        XCTAssertEqual(requests[0], requests[1])
    }
}

private final class UsageLogSink: AgentLogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AgentLogEntry] = []
    var entries: [AgentLogEntry] { lock.withLock { storage } }
    func log(_ entry: AgentLogEntry) { lock.withLock { storage.append(entry) } }
}

private final class UsageRequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Data] = []
    var bodies: [Data] { lock.withLock { storage } }
    func append(_ body: Data) { lock.withLock { storage.append(body) } }
    func reset() { lock.withLock { storage.removeAll() } }
}

private extension CodexResponsesBackend {
    func useDeterministicUsageTestEncoder() {
        // Ordinary JSONEncoder key ordering is unspecified across independent requests.
        encoder.outputFormatting = [.sortedKeys]
    }
}
