@testable import CodexKit
import CodexKitRealm
import CodexKitSQLite
import Darwin
import XCTest

final class StorageQueueCancellationTests: XCTestCase {
    func testCancellationDoesNotWaitForAnotherProcessToReleaseItsLock() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let root = directory.appendingPathComponent("attachments")
        let owner = Process()
        let input = Pipe()
        let output = Pipe()
        owner.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        owner.arguments = ["python3", "-c",
            "import fcntl, sys; f=open(sys.argv[1], 'a+'); fcntl.flock(f, fcntl.LOCK_EX); print('ready', flush=True); sys.stdin.read(1)",
            RuntimeStoreInterprocessLock.lockURL(for: root).path]
        owner.standardInput = input
        owner.standardOutput = output
        try owner.run()
        defer {
            try? input.fileHandleForWriting.close()
            owner.waitUntilExit()
        }
        let ready = try XCTUnwrap(output.fileHandleForReading.read(upToCount: 6))
        XCTAssertEqual(String(decoding: ready, as: UTF8.self), "ready\n")
        let finished = XCTestExpectation(description: "Waiter cancelled while other process holds lease")
        let task = Task {
            defer { finished.fulfill() }
            let lease = try await RuntimeStoreInterprocessLock.acquire(for: root)
            lease.release()
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await fulfillment(of: [finished], timeout: 3)
        XCTAssertTrue(owner.isRunning)
        try input.fileHandleForWriting.close()
        owner.waitUntilExit()
        await assertCancelled(task)
        XCTAssertEqual(owner.terminationStatus, 0)
    }

    func testPrecancelledAcquisitionCreatesNoLockFile() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("attachments")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            let lease = try await RuntimeStoreInterprocessLock.acquire(for: root)
            lease.release()
        }
        await assertCancelled(task)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testCancelledLockWaitersCloseTheirDescriptors() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("attachments")
        let held = try await RuntimeStoreInterprocessLock.acquire(for: root)
        defer { held.release() }
        let lockPath = RuntimeStoreInterprocessLock.lockURL(for: root).path
        let initial = try descriptorCount(for: lockPath)
        XCTAssertEqual(initial, 1)
        let completed = (0..<24).map { XCTestExpectation(description: "Cancelled waiter \($0)") }
        let tasks = completed.map { finished in
            Task {
                defer { finished.fulfill() }
                let lease = try await RuntimeStoreInterprocessLock.acquire(for: root)
                lease.release()
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertGreaterThan(try descriptorCount(for: lockPath), initial)
        tasks.forEach { $0.cancel() }
        await fulfillment(of: completed, timeout: 3)
        for task in tasks { await assertCancelled(task) }
        XCTAssertEqual(try descriptorCount(for: lockPath), initial)
    }

    func testCancelledExclusiveWaitReleasesAlreadyAcquiredLocks() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("a/attachments")
        let second = directory.appendingPathComponent("b/attachments")
        let held = try await RuntimeStoreInterprocessLock.acquire(for: second)
        let finished = XCTestExpectation(description: "Exclusive waiter cancelled")
        let waiter = Task {
            defer { finished.fulfill() }
            try await RuntimeStoreMutationCoordinator.shared.performExclusively(for: [second, first]) {
                XCTFail("Cancelled exclusive work must not run")
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(try descriptorCount(for: RuntimeStoreInterprocessLock.lockURL(for: first).path), 1)
        waiter.cancel()
        await fulfillment(of: [finished], timeout: 3)
        held.release()
        await assertCancelled(waiter)
        XCTAssertEqual(try descriptorCount(for: RuntimeStoreInterprocessLock.lockURL(for: first).path), 0)
        try await RuntimeStoreMutationCoordinator.shared.performExclusively(for: [first, second]) {  }
    }

    func testCancelledMiddleMutationCannotLetASuccessorOvertakeACommit() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("attachments")
        let started = AgentTurnReadiness()
        let release = AgentTurnReadiness()
        let events = StorageTestEvents()
        let first = Task {
            try await RuntimeStoreMutationCoordinator.shared.perform(for: root) {
                await events.append("first_started")
                await started.resolve(.success(()))
                try await release.wait()
                XCTAssertFalse(Task.isCancelled)
                await events.append("first_committed")
            }
        }
        try await started.wait()
        let cancelled = XCTestExpectation(description: "Middle mutation cancelled")
        let middle = Task {
            defer { cancelled.fulfill() }
            try await RuntimeStoreMutationCoordinator.shared.perform(for: root) {
                await events.append("middle")
            }
        }
        try await Task.sleep(for: .milliseconds(30))
        first.cancel() // The commit is protected even if its original caller leaves.
        middle.cancel()
        await fulfillment(of: [cancelled], timeout: 3)
        let last = Task {
            try await RuntimeStoreMutationCoordinator.shared.perform(for: root) { await events.append("last") }
        }
        try await Task.sleep(for: .milliseconds(50))
        let whileHeld = await events.values
        XCTAssertEqual(whileHeld, ["first_started"])
        await release.resolve(.success(()))
        try await first.value
        await assertCancelled(middle)
        try await last.value
        let final = await events.values
        XCTAssertEqual(final, ["first_started", "first_committed", "last"])
    }

    func testPersistenceQueueCancelsQueuedWritesAndReadsWithoutOvertaking() async throws {
        let store = StorageGatedStore()
        let coordinator = AgentRuntimePersistenceCoordinator(store: store)
        let first = Task { try await coordinator.apply([.upsertThread(.init(id: "first"))]) }
        try await store.started.wait()
        let writeDone = XCTestExpectation(description: "Queued write cancelled")
        let readDone = XCTestExpectation(description: "Queued read cancelled")
        let second = Task {
            defer { writeDone.fulfill() }
            try await coordinator.apply([.upsertThread(.init(id: "cancelled"))])
        }
        let read = Task {
            defer { readDone.fulfill() }
            _ = try await coordinator.loadThreadActivationState(id: "first", policy: .init())
        }
        try await Task.sleep(for: .milliseconds(30))
        second.cancel()
        read.cancel()
        await fulfillment(of: [writeDone, readDone], timeout: 3)
        let last = Task { try await coordinator.apply([.upsertThread(.init(id: "last"))]) }
        try await Task.sleep(for: .milliseconds(50))
        let before = await store.writes
        XCTAssertEqual(before, ["first"])
        first.cancel()
        await store.release.resolve(.success(()))
        try await first.value
        await assertCancelled(second)
        await assertCancelled(read)
        try await last.value
        let after = await store.writes
        XCTAssertEqual(after, ["first", "last"])
    }

    func testCancellingOnePreparationWaiterKeepsSharedPreparationUsable() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for kind in ["sqlite", "realm"] {
            let store = try makeStore(kind, directory: directory)
            let root = try XCTUnwrap(store as? any StoreMigrationCoordinating).migrationCoordinationRootURL
            let held = try await RuntimeStoreInterprocessLock.acquire(for: root)
            let finished = XCTestExpectation(description: "\(kind) preparation waiter cancelled")
            let first = Task {
                defer { finished.fulfill() }
                _ = try await store.prepare()
            }
            let second = Task { try await store.prepare() }
            try await Task.sleep(for: .milliseconds(50))
            first.cancel()
            await fulfillment(of: [finished], timeout: 3)
            held.release()
            await assertCancelled(first)
            _ = try await second.value
            try await store.apply([.upsertThread(.init(id: "after-preparation"))])
            let stored = try await store.loadState()
            XCTAssertEqual(stored.threads.map(\.id), ["after-preparation"])
        }
    }

    func testCancelledDirectStoreWritesNeverRunAfterTheLockIsReleased() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for kind in ["sqlite", "realm", "file"] {
            let store = try makeStore(kind, directory: directory)
            _ = try await store.prepare()
            let root = try XCTUnwrap(store as? any StoreMigrationCoordinating).migrationCoordinationRootURL
            let held = try await RuntimeStoreInterprocessLock.acquire(for: root)
            let finished = XCTestExpectation(description: "\(kind) write cancelled")
            let task = Task {
                defer { finished.fulfill() }
                try await store.apply([.upsertThread(.init(id: "must-not-exist"))])
            }
            try await Task.sleep(for: .milliseconds(50))
            task.cancel()
            await fulfillment(of: [finished], timeout: 3)
            held.release()
            await assertCancelled(task)
            try await store.apply([.upsertThread(.init(id: "later"))])
            let state = try await store.loadState()
            XCTAssertEqual(state.threads.map(\.id), ["later"])
        }
    }

    func testRuntimeStartupCancellationDoesNotWaitForAContendedStore() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for kind in ["sqlite", "realm", "file"] {
            let store = try makeStore(kind, directory: directory)
            let runtime = try AgentRuntime(configuration: .init(sessionProvider: DesignReadOnlyProvider(),
                backend: DesignBackend(), approvalPresenter: AutoApprovalPresenter(), stateStore: store))
            let thread = try await runtime.createThread()
            let root = try XCTUnwrap(store as? any StoreMigrationCoordinating).migrationCoordinationRootURL
            let held = try await RuntimeStoreInterprocessLock.acquire(for: root)
            let finished = XCTestExpectation(description: "\(kind) runtime start cancelled")
            let task = Task {
                defer { finished.fulfill() }
                _ = try await runtime.start(Request(text: "Accepted input"), in: thread.id)
            }
            try await Task.sleep(for: .milliseconds(50))
            task.cancel()
            await fulfillment(of: [finished], timeout: 3)
            let status = await runtime.thread(for: thread.id)?.status
            XCTAssertEqual(status, .idle)
            held.release()
            await assertCancelled(task)
            try await runtime.persistState()
            let saved = try await store.loadState()
            XCTAssertEqual(saved.messagesByThread[thread.id]?.map(\.text), ["Accepted input"])
            XCTAssertEqual(saved.summariesByThread[thread.id]?.latestTurnStatus, .interrupted)
            let next = try await runtime.send(Request(text: "Continue"), in: thread.id)
            XCTAssertEqual(next, "Done")
        }
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("CodexKitLockTests-\(UUID().uuidString)")
    }

    private func makeStore(_ kind: String, directory: URL) throws -> any RuntimeStateStoring {
        let url = directory.appendingPathComponent(kind)
        switch kind {
        case "sqlite": return try SQLiteRuntimeStateStore(url: url)
        case "realm": return try RealmRuntimeStateStore(url: url)
        default: return FileRuntimeStateStore(url: url)
        }
    }

    private func assertCancelled(_ task: Task<Void, Error>, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await task.value; XCTFail("Expected cancellation", file: file, line: line) }
        catch { XCTAssertTrue(error is CancellationError, "\(error)", file: file, line: line) }
    }

    private func descriptorCount(for path: String) throws -> Int {
        (0..<getdtablesize()).filter { descriptor in
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            let status = buffer.withUnsafeMutableBufferPointer { fcntl(descriptor, F_GETPATH, $0.baseAddress!) }
            guard status == 0 else { return false }
            let found = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            return URL(fileURLWithPath: found).resolvingSymlinksInPath().path == path
        }.count
    }
}

private actor StorageTestEvents {
    var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

private actor StorageGatedStore: RuntimeStateStoring {
    let base = InMemoryRuntimeStateStore()
    let started = AgentTurnReadiness()
    let release = AgentTurnReadiness()
    var writes: [String] = []
    func loadState() async throws -> StoredRuntimeState { try await base.loadState() }
    func saveState(_ state: StoredRuntimeState) async throws { try await base.saveState(state) }
    func apply(_ operations: [AgentStoreWriteOperation]) async throws {
        let first = writes.isEmpty
        writes.append(contentsOf: operations.map(\.affectedThreadID))
        if first {
            await started.resolve(.success(()))
            try await release.wait()
            XCTAssertFalse(Task.isCancelled)
        }
        try await base.apply(operations)
    }
}
