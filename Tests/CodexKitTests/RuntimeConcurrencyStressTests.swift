@testable import CodexKit
import CodexKitRealm
import CodexKitSQLite
import XCTest

final class RuntimeConcurrencyStressTests: XCTestCase {
    func testConcurrentFileStoreLifecycle() async throws { try await RuntimeStressHarness(adapter: .file).run() }
    func testConcurrentSQLiteStoreLifecycle() async throws { try await RuntimeStressHarness(adapter: .sqlite).run() }
    func testConcurrentRealmStoreLifecycle() async throws { try await RuntimeStressHarness(adapter: .realm).run() }
}

private struct RuntimeStressHarness: Sendable {
    let adapter: TestStorageBackend
    private let workerCount = 6
    private let policy = AgentThreadActivationPolicy(
        maximumMessageCount: 8, maximumEstimatedTokens: 4_000, maximumHistoryRecordCount: 16)

    func run() async throws {
        let rawRounds = ProcessInfo.processInfo.environment["CODEXKIT_STRESS_ROUNDS"] ?? "6"
        let rounds = try XCTUnwrap(Int(rawRounds), "CODEXKIT_STRESS_ROUNDS must be an integer")
        guard (1...200).contains(rounds) else {
            throw AgentRuntimeError(code: "stress_configuration", message: "Stress rounds must be between 1 and 200.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CodexKitStress-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(adapter.rawValue)
        let backend = RuntimeStressBackend()
        var runtimes = try (0..<2).map { _ in try makeRuntime(url: url, backend: backend) }
        var threadIDs: [String] = []
        var expected: [RuntimeStressExpectedThread] = []
        for worker in 0..<workerCount {
            let runtime = runtimes[worker % runtimes.count]
            let thread = try await runtime.createThread()
            threadIDs.append(thread.id)
            let text = "worker-\(worker)-seed"
            let result = try await runtime.send(request(text), in: thread.id)
            XCTAssertEqual(result, "reply:\(text)")
            expected.append(.init(messages: [.init(role: .user, text: text), .init(role: .assistant, text: "reply:\(text)")]))
        }
        await backend.drainProducers()
        let start = ContinuousClock.now
        for round in 0..<rounds {
            let wave = RuntimeStressWave(threadIDs: threadIDs)
            await backend.setWave(wave)
            let watchdog = Task {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                await wave.fail(AgentRuntimeError(code: "stress_timeout", message: "Concurrent wave did not finish."))
            }
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for worker in 0..<workerCount {
                        let runtime = runtimes[worker % runtimes.count]
                        let threadID = threadIDs[worker]
                        group.addTask {
                            do {
                                try await runWorker(runtime: runtime, threadID: threadID, worker: worker,
                                    round: round, wave: wave)
                            } catch { await wave.fail(error); throw error }
                        }
                    }
                    let observedThreadIDs = threadIDs
                    group.addTask {
                        do {
                            try await wave.arrive("reader")
                            let reopened = try openStore(url)
                            for threadID in observedThreadIDs {
                                let activation = try await reopened.loadThreadActivationState(id: threadID, policy: policy)
                                XCTAssertEqual(activation.thread.id, threadID)
                                checkMessages(activation.effectiveMessages, threadID: threadID)
                            }
                        } catch { await wave.fail(error); throw error }
                    }
                    try await group.waitForAll()
                }
            } catch {
                watchdog.cancel()
                await backend.cancelProducers()
                throw error
            }
            watchdog.cancel()
            await backend.drainProducers()
            await backend.setWave(nil)
            for worker in 0..<workerCount {
                let kind = (round + worker) % 6
                if kind == 3 { expected[worker].compactions += 1 }
                else if kind != 4 {
                    let text = turnText(round: round, worker: worker)
                    expected[worker].messages.append(.init(role: .user, text: text))
                    if kind == 1 {
                        expected[worker].interruptions += 1
                        expected[worker].status = .interrupted
                    } else {
                        expected[worker].messages.append(.init(role: .assistant, text: "reply:\(text)"))
                        expected[worker].status = .completed
                    }
                }
            }
            for runtime in runtimes { try await runtime.persistState() }
            try await verifySavedState(url: url, threadIDs: threadIDs, expected: expected, round: round)

            // Replace both owning runtimes and their database connections regularly.
            // Each runtime owns three distinct threads in the same underlying store.
            if (round + 1).isMultiple(of: 4) || round == rounds - 1 {
                runtimes = try (0..<2).map { _ in try makeRuntime(url: url, backend: backend) }
                for worker in 0..<workerCount {
                    let runtime = runtimes[worker % runtimes.count]
                    _ = try await runtime.resumeThread(id: threadIDs[worker])
                    let effective = await runtime.effectiveHistory(for: threadIDs[worker])
                    XCTAssertTrue(effective.contains { $0.text == expected[worker].latestReply })
                    checkMessages(effective, threadID: threadIDs[worker])
                }
            }
        }
        let elapsed = start.duration(to: .now).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        print("STRESS adapter=\(adapter.rawValue) rounds=\(rounds) workers=\(workerCount) operations=\(rounds * workerCount) reader_reopens=\(rounds) runtime_reopens=\(((rounds + 3) / 4) * 2) seconds=\(String(format: "%.3f", seconds))")
    }

    private func runWorker(runtime: AgentRuntime, threadID: String, worker: Int, round: Int,
        wave: RuntimeStressWave) async throws {
        let kind = (round + worker) % 6
        if kind == 3 || kind == 4 {
            let compact = Task { try await runtime.compactThreadContext(id: threadID) }
            defer { compact.cancel() }
            try await wave.waitForArrival(threadID)
            try await assertBusy(runtime, threadID: threadID)
            if kind == 4 { compact.cancel() }
            else { await wave.release(threadID) }
            do {
                _ = try await compact.value
                XCTAssertNotEqual(kind, 4, "Cancelled compaction must fail before committing")
            } catch is CancellationError { XCTAssertEqual(kind, 4) }
        } else {
            let execution = try await runtime.start(request(turnText(round: round, worker: worker)), in: threadID)
            defer { execution.cancel() }
            try await execution.waitUntilReady()
            var sawDelta = false
            var text = ""
            var completed = false
            var interrupted = false
            do {
                for try await event in execution.events {
                    switch event {
                    case let .assistantMessageDelta(_, _, delta):
                        text += delta
                        if !sawDelta {
                            sawDelta = true
                            try await assertBusy(runtime, threadID: threadID)
                            if kind == 1 { execution.cancel() }
                            else { await wave.release(threadID) }
                        }
                    case .turnCompleted: completed = true
                    case .turnInterrupted: interrupted = true
                    default: break
                    }
                    // Different repeatable delays exercise capacity-one event queues.
                    if worker.isMultiple(of: 2) { try await Task.sleep(for: .milliseconds(2)) }
                    else { await Task.yield() }
                }
                XCTAssertNotEqual(kind, 1, "Cancelled turn must terminate with cancellation")
            } catch is CancellationError { XCTAssertEqual(kind, 1) }
            XCTAssertTrue(sawDelta)
            XCTAssertEqual(text, kind == 1 ? "reply:" : "reply:\(turnText(round: round, worker: worker))")
            XCTAssertEqual(completed, kind != 1)
            XCTAssertEqual(interrupted, kind == 1)
        }
        let thread = await runtime.thread(for: threadID)
        let active = await runtime.activeTurnID(in: threadID)
        XCTAssertEqual(thread?.status, .idle)
        XCTAssertNil(active)
    }

    private func assertBusy(_ runtime: AgentRuntime, threadID: String) async throws {
        do {
            let unexpected = try await runtime.start(Request(text: "must-not-be-accepted"), in: threadID)
            unexpected.cancel()
            XCTFail("An overlapping turn was accepted")
        } catch { XCTAssertEqual((error as? AgentRuntimeError)?.code, "thread_busy") }
        do {
            _ = try await runtime.compactThreadContext(id: threadID)
            XCTFail("An overlapping compaction was accepted")
        } catch { XCTAssertEqual((error as? AgentRuntimeError)?.code, "thread_busy") }
    }

    private func verifySavedState(url: URL, threadIDs: [String], expected: [RuntimeStressExpectedThread],
        round: Int) async throws {
        let reopened = try openStore(url)
        let saved = try await reopened.loadState()
        XCTAssertEqual(Set(saved.threads.map(\.id)), Set(threadIDs))
        for (worker, threadID) in threadIDs.enumerated() {
            let label = "\(adapter.rawValue), round \(round), worker \(worker)"
            let messages = saved.messagesByThread[threadID] ?? []
            XCTAssertEqual(messages.map { RuntimeStressExpectedMessage(role: $0.role, text: $0.text) },
                expected[worker].messages, label)
            checkMessages(messages, threadID: threadID)
            let history = saved.historyByThread[threadID] ?? []
            // System-event IDs describe relationships and can recur; the stored
            // sequence is the unique identity of a history occurrence.
            let sequences = history.map(\.sequenceNumber)
            XCTAssertEqual(sequences, sequences.sorted(), label)
            XCTAssertEqual(Set(sequences).count, sequences.count, label)
            let historyMessages = history.compactMap { record -> AgentMessage? in
                if case let .message(message) = record.item { return message }; return nil
            }
            XCTAssertEqual(historyMessages, messages, label)
            let events = history.compactMap { record -> AgentSystemEventRecord? in
                if case let .systemEvent(event) = record.item { return event }; return nil
            }
            XCTAssertEqual(events.filter { $0.type == .contextCompacted }.count, expected[worker].compactions, label)
            XCTAssertEqual(events.filter { $0.type == .turnInterrupted }.count, expected[worker].interruptions, label)
            XCTAssertEqual(saved.contextStateByThread[threadID]?.generation ?? 0, expected[worker].compactions, label)
            XCTAssertEqual(saved.summariesByThread[threadID]?.latestTurnStatus, expected[worker].status, label)
            XCTAssertNil(saved.summariesByThread[threadID]?.pendingState, label)
            XCTAssertEqual(saved.threads.first { $0.id == threadID }?.status, .idle, label)
            let activation = try await reopened.loadThreadActivationState(id: threadID, policy: policy)
            // Activation retains closed turns. Interrupted input stays in the
            // full transcript asserted above, but need not enter model context.
            XCTAssertTrue(activation.effectiveMessages.contains { $0.text == expected[worker].latestReply }, label)
            XCTAssertLessThanOrEqual(activation.effectiveMessages.count, policy.maximumMessageCount, label)
            checkMessages(activation.effectiveMessages, threadID: threadID)
        }
    }

    private func checkMessages(_ messages: [AgentMessage], threadID: String) {
        XCTAssertEqual(Set(messages.map(\.id)).count, messages.count)
        for message in messages {
            XCTAssertEqual(message.threadID, threadID)
            XCTAssertEqual(message.images.count, message.role == .user ? 1 : 0)
            for image in message.images {
                XCTAssertEqual(image.mimeType, .png)
                XCTAssertEqual(image.data, Self.imageBytes)
            }
        }
    }

    private func turnText(round: Int, worker: Int) -> String { "worker-\(worker)-round-\(round)" }
    private func request(_ text: String) -> Request {
        Request(text: text, images: [.init(id: "image-\(text)", mimeType: "image/png", data: Self.imageBytes)])
    }
    private func makeRuntime(url: URL, backend: RuntimeStressBackend) throws -> AgentRuntime {
        try AgentRuntime(configuration: .init(sessionProvider: DesignReadOnlyProvider(), backend: backend,
            approvalPresenter: AutoApprovalPresenter(), stateStore: openStore(url), maximumBufferedEvents: 1,
            turnLimits: .init(maximumDuration: 30),
            contextCompaction: .init(isEnabled: true, mode: .manual, strategy: .remoteOnly),
            threadActivationPolicy: policy))
    }
    private func openStore(_ url: URL) throws -> any RuntimeStateStoring {
        try adapter.open(at: url)
    }
    private static let imageBytes = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!
}

private struct RuntimeStressExpectedMessage: Equatable, Sendable {
    let role: AgentRole
    let text: String
}

private struct RuntimeStressExpectedThread: Sendable {
    var messages: [RuntimeStressExpectedMessage]
    var compactions = 0
    var interruptions = 0
    var status = AgentTurnStatus.completed
    var latestReply: String? { messages.last { $0.role == .assistant }?.text }
}
