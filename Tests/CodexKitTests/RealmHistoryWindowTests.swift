@testable import CodexKit
import CodexKitRealm
import XCTest

final class RealmHistoryWindowTests: XCTestCase {
    func testConsecutivePagesMatchReferenceStoreInBothDirections() async throws {
        try await comparePages(firstSequence: 1, count: 36)
    }

    func testRestoredAndNearMaximumSequencesFallBackWithoutLosingRecords() async throws {
        try await comparePages(firstSequence: 10_000, count: 12)
        try await comparePages(firstSequence: Int.max - 12, count: 12)
    }

    func testExcludedMarkersAndRedactionsPreservePagingAndSortSemantics() async throws {
        try await comparePages(firstSequence: 1, count: 24, mixed: true)
    }

    func testEmptyHistoryAndOutOfRangeCursorsMatchReferenceStore() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try RealmRuntimeStateStore(url: directory.appendingPathComponent("history.realm"))
        let reference = InMemoryRuntimeStateStore()
        let state = StoredRuntimeState(threads: [.init(id: "empty")])
        try await store.saveState(state)
        try await reference.saveState(state)
        for anchor in [Int.min, 0, 1, Int.max] {
            for direction in [AgentHistoryDirection.forward, .backward] {
                let query = AgentHistoryQuery(limit: 3,
                    cursor: .init(threadID: "empty", sequenceNumber: anchor), direction: direction)
                let actual = try await store.fetchThreadHistory(id: "empty", query: query)
                let expected = try await reference.fetchThreadHistory(id: "empty", query: query)
                XCTAssertEqual(actual, expected)
            }
        }
    }

    private func comparePages(firstSequence: Int, count: Int, mixed: Bool = false) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.realm")
        let writer = try RealmRuntimeStateStore(url: url)
        let reference = InMemoryRuntimeStateStore()
        let threadID = "history:with:separators"
        let records = (0..<count).map { offset in
            let date = Date(timeIntervalSince1970: Double(offset % 5))
            let item: AgentHistoryItem = mixed && offset.isMultiple(of: 4)
                ? .systemEvent(.init(type: .contextCompacted, threadID: threadID,
                    memoryApplication: nil, occurredAt: date))
                : .message(.init(id: "message-\(offset)", threadID: threadID,
                    role: offset.isMultiple(of: 2) ? .user : .assistant, text: "Message \(offset)", createdAt: date))
            return AgentHistoryRecord(id: "record-\(offset)", sequenceNumber: firstSequence + offset,
                createdAt: date, item: item,
                redaction: mixed && offset.isMultiple(of: 3) ? .init(redactedAt: date) : nil)
        }
        let state = StoredRuntimeState(threads: [.init(id: threadID)], historyByThread: [threadID: records])
        try await writer.saveState(state)
        try await reference.saveState(state)
        let store = try RealmRuntimeStateStore(url: url)
        for direction in [AgentHistoryDirection.forward, .backward] {
            var cursor: AgentHistoryCursor?
            for _ in 0...count / 3 {
                let query = AgentHistoryQuery(limit: 3, cursor: cursor, direction: direction)
                let expected = try await reference.fetchThreadHistory(id: threadID, query: query)
                let actual = try await store.fetchThreadHistory(id: threadID, query: query)
                XCTAssertEqual(actual, expected)
                cursor = expected.nextCursor
                if cursor == nil { break }
            }
            for sort in [AgentHistorySort.sequence(.ascending), .sequence(.descending), .createdAt(.ascending)] {
                let variants = [
                    HistoryItemsQuery(threadID: threadID),
                    HistoryItemsQuery(threadID: threadID, includeRedacted: false, includeCompactionEvents: true),
                    HistoryItemsQuery(threadID: threadID, kinds: [.systemEvent], includeCompactionEvents: true),
                    HistoryItemsQuery(threadID: threadID, createdAtRange: Date(timeIntervalSince1970: 1)...Date(timeIntervalSince1970: 3)),
                    HistoryItemsQuery(threadID: threadID, turnID: "missing"),
                ]
                for var query in variants {
                    query.sort = sort
                    query.page = .init(limit: 3, direction: direction)
                    for _ in 0...count / 3 {
                        let expected = try await reference.execute(query)
                        let actual = try await store.execute(query)
                        XCTAssertEqual(actual, expected)
                        query.page?.cursor = expected.nextCursor
                        if expected.nextCursor == nil { break }
                    }
                }
            }
        }
        if !mixed {
            let policy = AgentThreadActivationPolicy(maximumMessageCount: 4,
                maximumEstimatedTokens: 1_000, maximumHistoryRecordCount: 4)
            let activation = try await store.loadThreadActivationState(id: threadID, policy: policy)
            XCTAssertEqual(activation.effectiveMessages.map(\.id), (count - 4..<count).map { "message-\($0)" })
        }
    }
}
