@testable import CodexKit
import CodexKitRealm
import CodexKitSQLite
import CoreGraphics
import Darwin
import ImageIO
import UniformTypeIdentifiers
import XCTest

/// Opt-in workloads report timing and process memory without timing assertions.
final class RealisticPerformanceTests: XCTestCase {
    func testImageHeavyRequestConstructionAndCompaction() async throws {
        try requireOptIn()
        await TestURLProtocol.reset()
        for count in [1, 4, 8] {
            let images = try (0..<count).map { try noiseImage(seed: UInt32($0 + 73)) }
            let attachmentBytes = images.reduce(0) { $0 + $1.data.count }
            let history = (0..<count).flatMap { index in [
                AgentMessage(threadID: "images", role: .user, text: "Image \(index)", images: [images[index]]),
                AgentMessage(threadID: "images", role: .assistant, text: "Noted"),
            ] }
            let items = history.map { WorkingHistoryItem.visibleMessage($0).jsonValue }
            let context = CodexResponsesProviderState(items: try CodexResponsesImageReferences.externalize(items)).agentProviderContext
            let backend = CodexResponsesBackend(urlSession: makeTestURLSession())
            let requestBytes = BenchmarkByteCount()
            await TestURLProtocol.enqueue(.init(body: Data("""
            data: {"type":"response.output_item.done","item":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Done"}]}}

            data: {"type":"response.completed","response":{"id":"finished"}}

            """.utf8), inspect: { request in try requestBytes.inspect(request) }))
            let before = ProcessMeasurement()
            let requestStart = ContinuousClock.now
            let turn = try await backend.beginTurn(thread: .init(id: "images"), history: history, providerContext: context,
                message: Request(text: "Continue"), instructions: "", responseFormat: nil, streamedStructuredOutput: nil,
                tools: [], session: demoSession())
            var completed = false
            for try await event in turn.events { if case .turnCompleted = event { completed = true } }
            XCTAssertTrue(completed)
            let requestMilliseconds = milliseconds(requestStart.duration(to: .now))
            await TestURLProtocol.enqueue(.init(body: try JSONEncoder().encode(JSONValue.object(["output": .array(items)])),
                inspect: { request in try requestBytes.inspect(request) }))
            let compactStart = ContinuousClock.now
            let compacted = try await backend.compactContext(thread: .init(id: "images"), effectiveHistory: history,
                providerContext: context, instructions: "", tools: [], session: demoSession())
            let compactMilliseconds = milliseconds(compactStart.duration(to: .now))
            XCTAssertEqual(compacted.effectiveMessages.flatMap(\.images).count, count)
            let storedPayload = try JSONEncoder().encode(compacted.providerContext)
            XCTAssertLessThan(storedPayload.count, 32_768)
            let after = ProcessMeasurement()
            print("BENCHMARK images count=\(count) attachment_bytes=\(attachmentBytes) largest_request_bytes=\(requestBytes.value) request_ms=\(requestMilliseconds) compaction_ms=\(compactMilliseconds) cpu_seconds=\(after.cpu - before.cpu) peak_rss_bytes=\(after.peak) initial_peak_rss_bytes=\(before.peak)")
        }
        await TestURLProtocol.reset()
    }

    func testLargeSQLiteAndRealmHistoryPagingAndActivation() async throws {
        try requireOptIn()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        for adapter in ["sqlite", "realm"] {
            for count in [2_000, 20_000] {
                let url = directory.appendingPathComponent("\(adapter)-\(count)")
                let open: () throws -> any RuntimeStateStoring & RuntimeStateInspecting = {
                    adapter == "sqlite" ? try SQLiteRuntimeStateStore(url: url) : try RealmRuntimeStateStore(url: url)
                }
                let thread = AgentThread(id: "history")
                let records = (1...count).map { sequence in
                    AgentHistoryRecord(sequenceNumber: sequence, createdAt: Date(timeIntervalSince1970: Double(sequence)),
                        item: .message(.init(id: "message-\(sequence)", threadID: thread.id,
                            role: sequence.isMultiple(of: 2) ? .assistant : .user,
                            text: "Record \(sequence): " + String(repeating: "history ", count: 64))))
                }
                let store = try open()
                let writeStart = ContinuousClock.now
                try await store.saveState(.init(threads: [thread], historyByThread: [thread.id: records]))
                let writeMilliseconds = milliseconds(writeStart.duration(to: .now))
                let reopened = try open()
                _ = try await reopened.prepare()
                let before = ProcessMeasurement()
                let activationStart = ContinuousClock.now
                let activation = try await reopened.loadThreadActivationState(id: thread.id,
                    policy: .init(maximumMessageCount: 16, maximumEstimatedTokens: 8_000, maximumHistoryRecordCount: 32))
                let activationMilliseconds = milliseconds(activationStart.duration(to: .now))
                XCTAssertLessThanOrEqual(activation.effectiveMessages.count, 16)
                XCTAssertEqual(activation.effectiveMessages.last?.id, "message-\(count)")
                let pagingStart = ContinuousClock.now
                var cursor: AgentHistoryCursor?
                var ids = Set<String>()
                for _ in 0..<5 {
                    let page = try await reopened.fetchThreadHistory(id: thread.id, query: .init(limit: 100, cursor: cursor))
                    XCTAssertEqual(page.items.count, 100)
                    for item in page.items {
                        guard case let .message(message) = item else { return XCTFail("Expected message history") }
                        XCTAssertTrue(ids.insert(message.id).inserted)
                    }
                    cursor = page.nextCursor
                    XCTAssertNotNil(cursor)
                }
                let pagingMilliseconds = milliseconds(pagingStart.duration(to: .now))
                let after = ProcessMeasurement()
                print("BENCHMARK history adapter=\(adapter) records=\(count) write_ms=\(writeMilliseconds) activation_ms=\(activationMilliseconds) five_pages_ms=\(pagingMilliseconds) hydrated_messages=\(activation.effectiveMessages.count) cpu_seconds=\(after.cpu - before.cpu) peak_rss_bytes=\(after.peak)")
            }
        }
    }

    func testCancellationLatencyWithSlowConsumers() async throws {
        try requireOptIn()
        for delay in [0, 25, 100] {
            let stopped = AgentTurnReadiness()
            let received = AgentTurnReadiness()
            let backend = BenchmarkStreamingBackend(stopped: stopped)
            let runtime = try AgentRuntime(configuration: .init(sessionProvider: DesignReadOnlyProvider(), backend: backend,
                approvalPresenter: AutoApprovalPresenter(), stateStore: InMemoryRuntimeStateStore(),
                maximumBufferedEvents: 1, turnLimits: .init(maximumDuration: 5)))
            let thread = try await runtime.createThread()
            let execution = try await runtime.start(Request(text: "Stream"), in: thread.id)
            let consumer = Task {
                do {
                    for try await event in execution.events {
                        if case .assistantMessageDelta = event { await received.resolve(.success(())) }
                        if delay > 0 { try await Task.sleep(for: .milliseconds(delay)) }
                    }
                    XCTFail("Expected interrupted execution")
                } catch is CancellationError {}
            }
            try await received.wait()
            let start = ContinuousClock.now
            execution.cancel()
            try await stopped.wait()
            let stoppedMilliseconds = milliseconds(start.duration(to: .now))
            try await consumer.value
            let drainedMilliseconds = milliseconds(start.duration(to: .now))
            let state = await runtime.thread(for: thread.id)
            XCTAssertEqual(state?.status, .idle)
            print("BENCHMARK cancellation consumer_delay_ms=\(delay) backend_stop_ms=\(stoppedMilliseconds) consumer_finish_ms=\(drainedMilliseconds)")
        }
    }

    private func requireOptIn() throws {
        guard ProcessInfo.processInfo.environment["CODEXKIT_RUN_PERFORMANCE_TESTS"] == "1" else {
            throw XCTSkip("Set CODEXKIT_RUN_PERFORMANCE_TESTS=1 for image, history, and cancellation workloads.")
        }
    }

    private func milliseconds(_ duration: Duration) -> String {
        let parts = duration.components
        return String(format: "%.3f", Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15)
    }

    private func noiseImage(seed initialSeed: UInt32) throws -> AgentImageAttachment {
        var seed = initialSeed
        var bytes = [UInt8](repeating: 255, count: 512 * 512 * 4)
        for index in bytes.indices where index % 4 != 3 {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            bytes[index] = UInt8(truncatingIfNeeded: seed >> 24)
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(width: 512, height: 512, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 512 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: .init(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return .init(mimeType: "image/png", data: data as Data)
    }
}

private struct ProcessMeasurement {
    let peak: Int
    let cpu: Double
    init() {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        peak = Int(usage.ru_maxrss)
        cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
}

private final class BenchmarkByteCount: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = 0
    var value: Int { lock.withLock { bytes } }
    func inspect(_ request: URLRequest) throws {
        let data = try XCTUnwrap(requestBodyData(for: request))
        XCTAssertNil(data.range(of: Data("codexkit-image-ref:".utf8)))
        lock.withLock { bytes = max(bytes, data.count) }
    }
}

private struct BenchmarkStreamingBackend: AgentBackend {
    let stopped: AgentTurnReadiness
    func createThread(session: ChatGPTSession) async throws -> AgentThread { .init(id: UUID().uuidString) }
    func resumeThread(id: String, session: ChatGPTSession) async throws -> AgentThread { .init(id: id) }
    func beginTurn(thread: AgentThread, history: [AgentMessage], message: Request, instructions: String,
        responseFormat: AgentStructuredOutputFormat?, streamedStructuredOutput: AgentStreamedStructuredOutputRequest?,
        tools: [ToolDefinition], session: ChatGPTSession) async throws -> AgentTurnStream {
        let (events, continuation) = AgentEventChannel<AgentBackendEvent>.makeStream(capacity: 1)
        let producer = Task {
            do {
                let turn = AgentTurn(id: UUID().uuidString, threadID: thread.id)
                try await continuation.yield(.turnStarted(turn))
                for _ in 0..<10_000 {
                    try await continuation.yield(.assistantMessageDelta(threadID: thread.id, turnID: turn.id,
                        delta: String(repeating: "x", count: 1_024)))
                }
                try await continuation.yield(.turnCompleted(.init(threadID: thread.id, turnID: turn.id)))
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
            await stopped.resolve(.success(()))
        }
        return .init(events: events, steer: nil, interrupt: { producer.cancel() })
    }
}
