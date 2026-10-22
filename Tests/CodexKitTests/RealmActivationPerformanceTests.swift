@testable import CodexKit
@testable import CodexKitRealm
import RealmSwift
import XCTest

@MainActor
final class RealmActivationPerformanceTests: XCTestCase {
    func testRelationshipLookupBenchmark() async throws {
        guard ProcessInfo.processInfo.environment["CODEXKIT_RUN_PERFORMANCE_TESTS"] == "1" else {
            throw XCTSkip("Opt-in Realm relationship benchmark")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("history.realm")
        let store = try RealmRuntimeStateStore(url: url)
        let records = (1...20_000).map { index in
            AgentHistoryRecord(sequenceNumber: index, createdAt: Date(timeIntervalSince1970: Double(index)), item: .message(.init(id: "m-\(index)",
                threadID: "thread", role: index.isMultiple(of: 2) ? .assistant : .user, text: "Message")))
        }
        try await store.saveState(.init(threads: [.init(id: "thread"), .init(id: "other")],
            historyByThread: ["thread": records, "other": [.init(sequenceNumber: 1, createdAt: Date(timeIntervalSince1970: 1),
                item: .message(.init(id: "m-20000", threadID: "other", role: .user, text: "Other thread")))]]))
        let realm = try await Realm.open(configuration: RealmRuntimeStoreConfigurationBuilder(fileURL: url).build(),
            _isolation: MainActor.shared)
        let keys = Set(records.suffix(32).compactMap { $0.item.relationshipKey })
        var oldTimes: [Double] = [], newTimes: [Double] = []
        for _ in 0..<5 {
            let oldStart = ContinuousClock.now
            let old = Array(realm.objects(RealmRuntimeHistoryObject.self)
                .filter("threadID == %@", "thread").filter("relationshipKey IN %@", Array(keys)).prefix(65))
            oldTimes.append(ms(oldStart.duration(to: .now)))
            let newStart = ContinuousClock.now
            var new: [RealmRuntimeHistoryObject] = []
            for key in keys {
                new.append(contentsOf: realm.objects(RealmRuntimeHistoryObject.self)
                    .filter("relationshipKey == %@ AND threadID == %@", key, "thread").prefix(65 - new.count))
            }
            newTimes.append(ms(newStart.duration(to: .now)))
            XCTAssertEqual(Set(old.map(\.key)), Set(new.map(\.key)))
            XCTAssertEqual(new.count, 32)
            XCTAssertTrue(new.allSatisfy { $0.threadID == "thread" })
        }
        print("BENCHMARK realm_relationship records=20000 keys=32 old_median_ms=\(oldTimes.sorted()[2]) new_median_ms=\(newTimes.sorted()[2])")
    }

    private func ms(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }
}
