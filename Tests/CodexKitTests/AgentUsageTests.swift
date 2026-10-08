@testable import CodexKit
@testable import CodexKitSQLite
@testable import CodexKitRealm
import XCTest

final class AgentUsageTests: XCTestCase {
    static let full = #"{"input_tokens":100,"input_tokens_details":{"cached_tokens":25,"cache_write_tokens":60},"output_tokens":10,"output_tokens_details":{"reasoning_tokens":5},"total_tokens":110,"codex_rollout_budget_units":2.5,"future_field":{"private":"NEVER_LOG"}}"#

    func decode(_ json: String) throws -> AgentUsage {
        try JSONDecoder().decode(StreamUsage.self, from: Data(json.utf8)).assistantUsage
    }

    func testFullProviderFixturePreservesUnitsAndDoesNotDoubleCountDetails() throws {
        let usage = try decode(Self.full)
        XCTAssertEqual(usage.inputTokens, 100)
        XCTAssertEqual(usage.cachedInputTokens, 25)
        XCTAssertEqual(usage.cacheWriteInputTokens, 60)
        XCTAssertEqual(usage.outputTokens, 10)
        XCTAssertEqual(usage.reasoningOutputTokens, 5)
        XCTAssertEqual(usage.totalTokens, 110)
        XCTAssertEqual(usage.derivedTotalTokens, 110)
        XCTAssertEqual(usage.codexRolloutBudgetUnits, 2.5)
        for metric in AgentUsageMetric.allCases { XCTAssertEqual(usage.availability(of: metric), .complete) }
        XCTAssertFalse(usage.logMetadata.description.contains("NEVER_LOG"))
    }

    func testMissingZeroMalformedAndLegacyRemainDistinct() throws {
        let legacy = try JSONDecoder().decode(AgentUsage.self,
            from: Data(#"{"inputTokens":17,"cachedInputTokens":0,"outputTokens":0}"#.utf8))
        XCTAssertEqual(legacy.inputTokens, 17)
        XCTAssertNil(legacy.coverage)
        XCTAssertEqual(legacy.availability(of: .cachedInputTokens), .unknown)
        XCTAssertEqual(AgentUsage().availability(of: .inputTokens), .unknown)
        let missing = AgentUsage.unavailable()
        XCTAssertEqual(missing.coverage?.usageReportedResponseCount, 0)
        XCTAssertEqual(missing.availability(of: .inputTokens), .unavailable)
        let empty = try decode("{}")
        XCTAssertEqual(empty.coverage?.usageReportedResponseCount, 1)
        XCTAssertNil(empty.totalTokens)
        let zero = try decode(#"{"input_tokens":0,"output_tokens":0,"input_tokens_details":{"cached_tokens":0},"codex_rollout_budget_units":0}"#)
        XCTAssertEqual(zero.availability(of: .cachedInputTokens), .complete)
        XCTAssertEqual(zero.codexRolloutBudgetUnits, 0)
        XCTAssertEqual(zero.derivedTotalTokens, 0)
        XCTAssertEqual(try decode(#"{"codex_rollout_budget_units":-0.5}"#).codexRolloutBudgetUnits, -0.5)
        XCTAssertNil(zero.totalTokens)
        let bad = try decode(#"{"input_tokens":12,"output_tokens":4,"input_tokens_details":{"cached_tokens":"PRIVATE","cache_write_tokens":-1},"output_tokens_details":false,"total_tokens":1.2,"codex_rollout_budget_units":"SECRET"}"#)
        XCTAssertEqual(bad.inputTokens, 12)
        XCTAssertEqual(bad.outputTokens, 4)
        XCTAssertNil(bad.reasoningOutputTokens)
        XCTAssertNil(bad.totalTokens)
        XCTAssertEqual(bad.coverage?.invalidMetrics.count, 5)
        XCTAssertNil(bad.logMetadata["cached_input_tokens"])
        XCTAssertFalse(bad.logMetadata.description.contains("PRIVATE"))
        for json in ["false", "[]", "\"SECRET\"", #"{"input_tokens":9223372036854775808,"output_tokens":1}"#] {
            XCTAssertEqual(try decode(json).availability(of: .inputTokens), .unavailable)
        }
    }

    func testAggregationHasPerFieldCoverageAndOverflowCannotFailOutput() throws {
        var aggregate = AgentUsage.unavailable(responseCount: 0)
        aggregate.add(try decode(Self.full))
        aggregate.add(try decode(#"{"input_tokens":20,"output_tokens":0,"total_tokens":20}"#))
        XCTAssertEqual(aggregate.inputTokens, 120)
        XCTAssertEqual(aggregate.totalTokens, 130)
        XCTAssertEqual(aggregate.reasoningOutputTokens, 5)
        XCTAssertEqual(aggregate.availability(of: .inputTokens), .complete)
        XCTAssertEqual(aggregate.availability(of: .reasoningOutputTokens), .partial)
        aggregate.add(.unavailable())
        XCTAssertEqual(aggregate.coverage?.responseCount, 3)
        XCTAssertEqual(aggregate.availability(of: .inputTokens), .partial)
        XCTAssertNil(aggregate.derivedTotalTokens)
        var huge = try decode(#"{"input_tokens":9223372036854775807,"output_tokens":1}"#)
        XCTAssertNil(huge.derivedTotalTokens)
        huge.add(try decode(Self.full))
        huge.add(try decode(Self.full))
        XCTAssertEqual(huge.availability(of: .inputTokens), .unavailable)
        XCTAssertTrue(huge.coverage?.overflowedMetrics.contains(.inputTokens) == true)
    }

    func testUsageAndOldRecordsRoundTripThroughFileSQLiteAndRealm() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let factories: [() throws -> any RuntimeStateStoring] = [
            { FileRuntimeStateStore(url: directory.appendingPathComponent("state.json")) },
            { try SQLiteRuntimeStateStore(url: directory.appendingPathComponent("state.sqlite"),
                importingLegacyStateFrom: directory.appendingPathComponent("missing.json")) },
            { try RealmRuntimeStateStore(url: directory.appendingPathComponent("state.realm"),
                importingLegacyStateFrom: directory.appendingPathComponent("missing.json")) }
        ]
        let legacy = try JSONDecoder().decode(AgentUsage.self,
            from: Data(#"{"inputTokens":12,"cachedInputTokens":0,"outputTokens":0}"#.utf8))
        let usages = [legacy, try decode(Self.full)]
        for factory in factories {
            var state = StoredRuntimeState.empty
            state.threads = [AgentThread(id: "thread")]
            state.historyByThread["thread"] = usages.enumerated().map { index, usage in
                AgentHistoryRecord(sequenceNumber: index + 1, createdAt: Date(), item: .systemEvent(
                    .init(type: .turnCompleted, threadID: "thread", turnID: "turn-\(index)",
                        turnSummary: .init(threadID: "thread", turnID: "turn-\(index)", usage: usage))))
            }
            try await factory().saveState(state)
            let reopened = try await factory().loadState()
            let actual = reopened.historyByThread["thread"]?.compactMap { record -> AgentUsage? in
                if case let .systemEvent(event) = record.item { return event.turnSummary?.usage }
                return nil
            }
            XCTAssertEqual(actual, usages)
        }
    }
}
