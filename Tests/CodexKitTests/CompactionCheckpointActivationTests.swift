@testable import CodexKit
import CodexKitSQLite
import CodexKitRealm
import XCTest

final class CompactionCheckpointActivationTests: XCTestCase {
    func testReopeningBoundsRetainedUsersWithoutDroppingCheckpoint() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let messages = ["Old question", "Recent question"].map {
            AgentMessage(threadID: "thread", role: .user, text: $0)
        }
        let context = CodexResponsesProviderState(items: messages.map { WorkingHistoryItem.visibleMessage($0).jsonValue }
            + [checkpoint]).agentProviderContext
        for adapter in [TestStorageBackend.file, .sqlite, .realm] {
            let url = root.appendingPathComponent(adapter.rawValue)
            let open: () throws -> any RuntimeStateStoring = {
                return try adapter.open(at: url)
            }
            let store = try open()
            try await store.saveState(.init(threads: [.init(id: "thread")], contextStateByThread: ["thread": .init(
                threadID: "thread", effectiveMessages: messages, providerContext: context, generation: 1)]))
            let reopened = try open()
            let state = try await reopened.loadThreadActivationState(id: "thread", policy: .init(maximumMessageCount: 1))
            XCTAssertEqual(state.effectiveMessages.map(\.text), ["Recent question"])
            let items = state.contextState?.providerContext?.payload.objectValue?["items"]?.arrayValue
            XCTAssertEqual(items?.count, 2)
            XCTAssertEqual(items?.last, checkpoint)
            XCTAssertEqual(items?.first?.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"], .string("Recent question"))
        }
    }

    func testCheckpointDoesNotMakeLaterUnfinishedInputAClosedTurn() {
        let retained = AgentMessage(threadID: "thread", role: .user, text: "Compacted")
        let pending = AgentMessage(threadID: "thread", role: .user, text: "Unfinished")
        let context = CodexResponsesProviderState(items: [WorkingHistoryItem.visibleMessage(retained).jsonValue, checkpoint])
            .agentProviderContext
        let ids = CodexResponsesCheckpointContext.completedMessageIDs(context: context, messages: [retained, pending])
        XCTAssertEqual(ids, [retained.id])
        let bounded = AgentThreadContextWindow.boundedMessages([retained, pending], policy: .init(),
            requireClosedTurns: true, completedMessageIDs: ids)
        XCTAssertEqual(bounded, [retained])
        XCTAssertNil(CodexResponsesCheckpointContext.rebase(context: context, original: [retained, pending], retained: bounded))
        XCTAssertTrue(CodexResponsesCheckpointContext.completedMessageIDs(context: context, messages: [pending]).isEmpty)
    }

    func testTrimmingCompactedPrefixPreservesLaterCompleteConversation() {
        let retained = AgentMessage(threadID: "thread", role: .user, text: "Compacted")
        let user = AgentMessage(threadID: "thread", role: .user, text: "New")
        let reply = AgentMessage(threadID: "thread", role: .assistant, text: "Answer")
        let suffix = [user, reply].map { WorkingHistoryItem.visibleMessage($0).jsonValue }
        let context = CodexResponsesProviderState(items: [WorkingHistoryItem.visibleMessage(retained).jsonValue, checkpoint] + suffix)
            .agentProviderContext
        let rebased = CodexResponsesCheckpointContext.rebase(context: context, original: [retained, user, reply], retained: [user, reply])
        XCTAssertEqual(rebased?.payload.objectValue?["items"]?.arrayValue, [checkpoint] + suffix)
        XCTAssertNil(CodexResponsesCheckpointContext.rebase(context: context, original: [retained, user, reply], retained: [reply]))
    }

    private var checkpoint: JSONValue {
        .object(["type": .string("compaction"), "encrypted_content": .string("opaque")])
    }
}
