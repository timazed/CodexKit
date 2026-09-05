@testable import CodexKit
@testable import CodexKitSQLite
@testable import CodexKitRealm
import XCTest

final class AgentProgressPersistenceTests: XCTestCase {
    func testPhaseAndInterruptedHistorySurviveEachPersistentStore() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stores: [any RuntimeStateStoring] = [
            FileRuntimeStateStore(url: directory.appendingPathComponent("state.json")),
            try SQLiteRuntimeStateStore(url: directory.appendingPathComponent("state.sqlite"),
                importingLegacyStateFrom: directory.appendingPathComponent("missing.json")),
            try RealmRuntimeStateStore(url: directory.appendingPathComponent("state.realm"),
                importingLegacyStateFrom: directory.appendingPathComponent("missing.json"))
        ]
        for store in stores {
            let thread = AgentThread(id: "thread")
            let message = AgentMessage(id: "message", threadID: thread.id, role: .assistant,
                text: "Checking", phase: .commentary)
            let records = [
                AgentHistoryRecord(sequenceNumber: 1, createdAt: Date(), item: .message(message)),
                AgentHistoryRecord(sequenceNumber: 2, createdAt: Date(), item: .systemEvent(.init(type: .turnStarted, threadID: thread.id, turnID: "turn"))),
                AgentHistoryRecord(sequenceNumber: 3, createdAt: Date(), item: .systemEvent(.init(type: .turnInterrupted, threadID: thread.id, turnID: "turn")))
            ]
            var state = StoredRuntimeState.empty
            state.threads = [thread]
            state.messagesByThread[thread.id] = [message]
            state.historyByThread[thread.id] = records
            try await store.saveState(state)
            let loaded = try await store.loadState()
            XCTAssertEqual(loaded.messagesByThread[thread.id]?.first?.phase, .commentary)
            XCTAssertTrue(loaded.historyByThread[thread.id]?.contains {
                if case let .systemEvent(event) = $0.item { return event.type == .turnInterrupted }
                return false
            } == true)
        }
    }
}
