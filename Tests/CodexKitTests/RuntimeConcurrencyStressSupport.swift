@testable import CodexKit
import Foundation

/// Every wave reaches six backend operations plus a fresh database reader before
/// any operation can complete. Gates make cancellation precede the commit boundary.
actor RuntimeStressWave {
    private let started: [String: AgentTurnReadiness]
    private let permits: [String: AgentTurnReadiness]
    private let allArrived = AgentTurnReadiness()
    private var arrivals = Set<String>()

    init(threadIDs: [String]) {
        started = Dictionary(uniqueKeysWithValues: threadIDs.map { ($0, AgentTurnReadiness()) })
        permits = Dictionary(uniqueKeysWithValues: threadIDs.map { ($0, AgentTurnReadiness()) })
    }

    func arrive(_ id: String) async throws {
        guard arrivals.insert(id).inserted else {
            throw AgentRuntimeError(code: "stress_duplicate_arrival", message: "Operation entered a wave twice.")
        }
        await started[id]?.resolve(.success(()))
        if arrivals.count == started.count + 1 { await allArrived.resolve(.success(())) }
        try await allArrived.wait()
    }

    func waitForArrival(_ id: String) async throws {
        try await started[id]?.wait()
        try await allArrived.wait()
    }

    func waitForRelease(_ id: String) async throws { try await permits[id]?.wait() }
    func release(_ id: String) async { await permits[id]?.resolve(.success(())) }

    func fail(_ error: Error) async {
        await allArrived.resolve(.failure(error))
        for gate in started.values { await gate.resolve(.failure(error)) }
        for gate in permits.values { await gate.resolve(.failure(error)) }
    }
}

actor RuntimeStressBackend: AgentBackend, AgentBackendContextCompacting {
    private var wave: RuntimeStressWave?
    private var producers: [Task<Void, Never>] = []

    func setWave(_ wave: RuntimeStressWave?) { self.wave = wave }
    func createThread(session: ChatGPTSession) async throws -> AgentThread { .init(id: UUID().uuidString) }
    func resumeThread(id: String, session: ChatGPTSession) async throws -> AgentThread { .init(id: id) }

    func beginTurn(thread: AgentThread, history: [AgentMessage], message: Request, instructions: String,
        responseFormat: AgentStructuredOutputFormat?, streamedStructuredOutput: AgentStreamedStructuredOutputRequest?,
        tools: [ToolDefinition], session: ChatGPTSession) async throws -> AgentTurnStream {
        let wave = wave
        try await wave?.arrive(thread.id)
        let (events, continuation) = AgentEventChannel<AgentBackendEvent>.makeStream(capacity: 1)
        let producer = Task {
            do {
                let turn = AgentTurn(id: "turn-\(message.text)", threadID: thread.id)
                try await continuation.yield(.turnStarted(turn))
                try await continuation.yield(.assistantMessageDelta(threadID: thread.id, turnID: turn.id, delta: "reply:"))
                try await wave?.waitForRelease(thread.id)
                for (index, fragment) in message.text.split(separator: "-").enumerated() {
                    let delta = (index == 0 ? "" : "-") + fragment
                    try await continuation.yield(.assistantMessageDelta(threadID: thread.id, turnID: turn.id, delta: delta))
                    await Task.yield()
                }
                try await continuation.yield(.assistantMessageCompleted(.init(id: "reply-\(message.text)",
                    threadID: thread.id, role: .assistant, text: "reply:\(message.text)")))
                try await continuation.yield(.turnCompleted(.init(threadID: thread.id, turnID: turn.id)))
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
        producers.append(producer)
        return .init(events: events, steer: nil, interrupt: { producer.cancel() })
    }

    func compactContext(thread: AgentThread, effectiveHistory: [AgentMessage], instructions: String,
        tools: [ToolDefinition], session: ChatGPTSession) async throws -> AgentCompactionResult {
        let wave = wave
        try await wave?.arrive(thread.id)
        try await wave?.waitForRelease(thread.id)
        return .init(effectiveMessages: Array(effectiveHistory.suffix(2)))
    }

    func cancelProducers() async {
        producers.forEach { $0.cancel() }
        await drainProducers()
    }

    func drainProducers() async {
        let pending = producers
        producers.removeAll()
        for producer in pending { await producer.value }
    }
}
