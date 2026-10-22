@testable import CodexKit
@testable import CodexKitUI
import SwiftUI
import XCTest

@MainActor
final class PresentationPerformanceTests: XCTestCase {
    func testReasoningBatchRetainsBoundedUnicodeAndFinishesWithoutStaleProgress() async throws {
        let fragment = "Reasoning 😀 café. "
        let runtime = try AgentRuntime(configuration: .init(sessionProvider: DesignReadOnlyProvider(),
            backend: ReasoningBenchmarkBackend(fragment: fragment), approvalPresenter: AutoApprovalPresenter(),
            stateStore: InMemoryRuntimeStateStore()))
        let store = AgentRuntimeStore(runtime: runtime)
        await store.send("Go")
        XCTAssertEqual(store.reasoningSummary, String(String(repeating: fragment, count: 1_000).suffix(8_000)))
        XCTAssertNil(store.latestProgress)
        XCTAssertNil(store.lastError)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertNil(store.latestProgress)
        XCTAssertTrue(store.streamingText.isEmpty)
    }

    func testReasoningAndSwiftUIRenderingBenchmarks() throws {
        guard ProcessInfo.processInfo.environment["CODEXKIT_RUN_PERFORMANCE_TESTS"] == "1" else {
            throw XCTSkip("Opt-in presentation benchmark")
        }
        let fragment = "Reasoning 😀 café. "
        var old = "", new = ""
        let oldStart = ContinuousClock.now
        for _ in 0..<16_000 { old = String((old + fragment).suffix(8_000)) }
        let oldMS = ms(oldStart.duration(to: .now))
        let batch = StreamingTextBatcher()
        let newStart = ContinuousClock.now
        for index in 0..<16_000 {
            batch.append(fragment) { new = String((new + $0).suffix(8_000)) }
            if (index + 1).isMultiple(of: 32) { batch.flush() }
        }
        batch.flush()
        XCTAssertEqual(new, old)
        print("BENCHMARK reasoning chunks=16000 old_ms=\(oldMS) new_ms=\(ms(newStart.duration(to: .now)))")

        // Actual offscreen SwiftUI text rendering on each publication, with a
        // fixed viewport. This isolates rendering cost, not live app frame rate;
        // SwiftUI may already coalesce invalidations in a running application.
        var renderTimes: [Double] = []
        for batched in [false, true] {
            var text = ""
            var renders = 0
            func publish(_ delta: String) {
                text.append(delta)
                let renderer = ImageRenderer(content: Text(text).font(.body)
                    .frame(width: 480, height: 240, alignment: .topLeading).clipped())
                XCTAssertNotNil(renderer.cgImage)
                renders += 1
            }
            let start = ContinuousClock.now
            for index in 0..<128 {
                if batched {
                    batch.append(fragment, publish: publish)
                    if (index + 1).isMultiple(of: 8) { batch.flush() }
                } else { publish(fragment) }
            }
            batch.flush()
            renderTimes.append(ms(start.duration(to: .now)))
            XCTAssertEqual(text, String(repeating: fragment, count: 128))
            print("BENCHMARK swiftui_offscreen batched=\(batched) renders=\(renders) elapsed_ms=\(renderTimes.last!)")
        }
    }

    private func ms(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }
}

private struct ReasoningBenchmarkBackend: AgentBackend {
    let fragment: String
    func createThread(session: ChatGPTSession) async throws -> AgentThread { .init(id: UUID().uuidString) }
    func resumeThread(id: String, session: ChatGPTSession) async throws -> AgentThread { .init(id: id) }
    func beginTurn(thread: AgentThread, history: [AgentMessage], message: Request, instructions: String,
        responseFormat: AgentStructuredOutputFormat?, streamedStructuredOutput: AgentStreamedStructuredOutputRequest?,
        tools: [ToolDefinition], session: ChatGPTSession) async throws -> AgentTurnStream {
        let turn = AgentTurn(id: "turn", threadID: thread.id)
        return .init(events: AsyncThrowingStream { continuation in
            continuation.yield(.turnStarted(turn))
            for _ in 0..<1_000 {
                continuation.yield(.progress(.init(threadID: thread.id, turnID: turn.id,
                    content: .reasoningSummaryDelta(itemID: "reasoning", summaryIndex: 0, delta: fragment))))
            }
            continuation.yield(.assistantMessageCompleted(.init(threadID: thread.id, role: .assistant, text: "Done")))
            continuation.yield(.turnCompleted(.init(threadID: thread.id, turnID: turn.id)))
            continuation.finish()
        })
    }
}
