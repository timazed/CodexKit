@testable import CodexKit
import CodexKitSQLite
import Darwin
import XCTest

final class RuntimeSystemBenchmarkTests: XCTestCase {
    func testHTTPToSQLiteThroughputAndProcessPeakMemory() async throws {
        guard ProcessInfo.processInfo.environment["CODEXKIT_RUN_PERFORMANCE_TESTS"] == "1" else {
            throw XCTSkip("Set CODEXKIT_RUN_PERFORMANCE_TESTS=1 for the full pipeline benchmark.")
        }
        await TestURLProtocol.reset()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteRuntimeStateStore(url: directory.appendingPathComponent("benchmark.sqlite"))
        let runtime = try AgentRuntime(configuration: .init(sessionProvider: DesignReadOnlyProvider(),
            backend: CodexResponsesBackend(configuration: .init(maximumBufferedEvents: 2), urlSession: makeTestURLSession()),
            approvalPresenter: AutoApprovalPresenter(), stateStore: store, maximumBufferedEvents: 2,
            threadActivationPolicy: .init(maximumMessageCount: 8, maximumEstimatedTokens: 4_000, maximumHistoryRecordCount: 16)))
        let thread = try await runtime.createThread()
        let fragment = "abcdefghijklmnop"
        let delta = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"\(fragment)\"}\n\n"
        let text = String(repeating: fragment, count: 50)
        let before = usage()
        let start = ContinuousClock.now
        for turn in 1...100 {
            let body = String(repeating: delta, count: 50) + """
            data: {"type":"response.output_item.done","item":{"id":"message-\(turn)","type":"message","role":"assistant","content":[{"type":"output_text","text":"\(text)"}]}}

            data: {"type":"response.completed","response":{"id":"response-\(turn)"}}

            """
            await TestURLProtocol.enqueue(.init(body: Data(body.utf8)))
            let result = try await runtime.send(Request(text: "Continue"), in: thread.id)
            XCTAssertEqual(result, text)
            let historyCount = await runtime.state.historyByThread[thread.id]?.count ?? 0
            let messages = await runtime.messages(for: thread.id)
            XCTAssertLessThanOrEqual(historyCount, 16)
            XCTAssertLessThanOrEqual(messages.count, 8)
            if [10, 50, 100].contains(turn) {
                let current = usage()
                let duration = start.duration(to: .now).components
                let seconds = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
                print("BENCHMARK pipeline turns=\(turn) deltas=\(turn * 50) seconds=\(String(format: "%.3f", seconds)) cpu_seconds=\(String(format: "%.3f", current.cpu - before.cpu)) process_peak_rss_bytes=\(current.peak) initial_peak_rss_bytes=\(before.peak) live_history=\(historyCount) live_messages=\(messages.count)")
            }
        }
        let summary = try await runtime.fetchThreadSummary(id: thread.id)
        XCTAssertGreaterThan(summary.itemCount ?? 0, 16)
        await TestURLProtocol.reset()
    }

    private func usage() -> (peak: Int, cpu: Double) {
        var value = rusage()
        getrusage(RUSAGE_SELF, &value)
        let cpu = Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec)
            + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1_000_000
        return (Int(value.ru_maxrss), cpu)
    }
}
