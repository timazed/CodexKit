@testable import CodexKit
import XCTest

final class PreparationCancellationTests: XCTestCase {
    func testPrecancelledPlainAndStructuredStartsNeverPersistOrLaunch() async throws {
        for ephemeral in [false, true] {
            for structured in [false, true] {
                let backend = PreparationBackend()
                let store = InMemoryRuntimeStateStore()
                let runtime = try runtime(backend: backend, store: store)
                let thread = try await runtime.createThread()
                let before = try await store.loadState()
                let task = Task {
                    withUnsafeCurrentTask { $0?.cancel() }
                    let request = Request(text: "Must not run", executionMode: ephemeral ? .ephemeral : .threaded)
                    if structured { _ = try await runtime.start(request, in: thread.id, response: PreparationOutput.self) }
                    else { _ = try await runtime.start(request, in: thread.id) }
                }
                do { try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {}
                let calls = await backend.calls
                let after = try await store.loadState()
                XCTAssertEqual(calls, 0)
                XCTAssertEqual(after, before)
            }
        }
    }

    func testCancellationDuringPreparationPreservesCommittedInputAndReleasesThread() async throws {
        for structured in [false, true] {
            let backend = PreparationBackend()
            let store = PreparationStore()
            let runtime = try runtime(backend: backend, store: store)
            let thread = try await runtime.createThread()
            await store.blockNextWrite()
            let task = Task {
                if structured {
                    _ = try await runtime.start(Request(text: "Cancelled input"), in: thread.id, response: PreparationOutput.self)
                } else { _ = try await runtime.start(Request(text: "Cancelled input"), in: thread.id) }
            }
            try await store.started.wait()
            task.cancel()
            await store.release.resolve(.success(()))
            do { try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {}
            let calls = await backend.calls
            let state = try await store.loadState()
            XCTAssertEqual(calls, 0)
            XCTAssertEqual(state.messagesByThread[thread.id]?.map(\.text), ["Cancelled input"])
            XCTAssertEqual(state.threads.first?.status, .idle)
            XCTAssertEqual(state.summariesByThread[thread.id]?.latestTurnStatus, .interrupted)
            let next = try await runtime.send(Request(text: "Next"), in: thread.id)
            XCTAssertEqual(next, "Done")
        }
    }

    private func runtime(backend: PreparationBackend, store: any RuntimeStateStoring) throws -> AgentRuntime {
        try .init(configuration: .init(sessionProvider: DesignReadOnlyProvider(), backend: backend,
            approvalPresenter: AutoApprovalPresenter(), stateStore: store))
    }
}

private struct PreparationOutput: AgentStructuredOutput {
    let value: String
    static let responseFormat = AgentStructuredOutputFormat(name: "output",
        schema: .object(properties: ["value": .string()], required: ["value"]))
}

private actor PreparationBackend: AgentBackend {
    var calls = 0
    func createThread(session: ChatGPTSession) async throws -> AgentThread { .init(id: UUID().uuidString) }
    func resumeThread(id: String, session: ChatGPTSession) async throws -> AgentThread { .init(id: id) }
    func beginTurn(thread: AgentThread, history: [AgentMessage], message: Request, instructions: String,
        responseFormat: AgentStructuredOutputFormat?, streamedStructuredOutput: AgentStreamedStructuredOutputRequest?,
        tools: [ToolDefinition], session: ChatGPTSession) async throws -> AgentTurnStream {
        calls += 1
        return try await DesignBackend().beginTurn(thread: thread, history: history, message: message, instructions: instructions,
            responseFormat: responseFormat, streamedStructuredOutput: streamedStructuredOutput, tools: tools, session: session)
    }
}

private actor PreparationStore: RuntimeStateStoring {
    let base = InMemoryRuntimeStateStore()
    let started = AgentTurnReadiness()
    let release = AgentTurnReadiness()
    private var block = false
    func blockNextWrite() { block = true }
    func loadState() async throws -> StoredRuntimeState { try await base.loadState() }
    func saveState(_ state: StoredRuntimeState) async throws { try await base.saveState(state) }
    func apply(_ operations: [AgentStoreWriteOperation]) async throws {
        if block {
            block = false
            await started.resolve(.success(()))
            try await release.wait()
        }
        try await base.apply(operations)
    }
}
