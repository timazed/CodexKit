@testable import CodexKit
import XCTest

struct PolicySessionProvider: AgentSessionProviding {
    func currentSession() async -> ChatGPTSession? { demoSession() }
}

func makePolicyRuntime(
    policy: AgentSkillExecutionPolicy? = nil, tools: [AgentRuntime.ToolRegistration] = [],
    maximumParallel: Int = 4, store: any RuntimeStateStoring = InMemoryRuntimeStateStore(),
    approvals: any ApprovalPresenting = AutoApprovalPresenter(),
    backend: (any AgentBackend)? = nil
) throws -> AgentRuntime {
    try AgentRuntime(configuration: .init(sessionProvider: PolicySessionProvider(),
        backend: backend ?? CodexResponsesBackend(configuration: .init(requestRetryPolicy: .disabled), urlSession: makeTestURLSession()),
        approvalPresenter: approvals, stateStore: store, maximumParallelToolCalls: maximumParallel,
        tools: tools, skills: policy.map { [.init(id: "policy", name: "Policy", instructions: "Use host tools.", executionPolicy: $0)] } ?? []))
}

func enqueuePolicyRound(_ names: [String], id: String = "round") async {
    let calls = names.enumerated().map { index, name in
        "data: {\"type\":\"response.output_item.done\",\"output_index\":\(index),\"item\":{\"type\":\"function_call\",\"name\":\"\(name)\",\"call_id\":\"\(id)-\(index)\",\"arguments\":\"{}\"}}\n\n"
    }.joined()
    await TestURLProtocol.enqueue(.init(body: Data((calls + "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"\(id)\"}}\n\n").utf8)))
}

func enqueuePolicyAnswer(inspect: @escaping @Sendable (URLRequest) throws -> Void = { _ in }) async {
    await TestURLProtocol.enqueue(.init(body: Data("""
    data: {"type":"response.output_item.done","item":{"id":"answer","type":"message","role":"assistant","phase":"final_answer","content":[{"type":"output_text","text":"Done"}]}}

    data: {"type":"response.completed","response":{"id":"answer"}}


    """.utf8), inspect: inspect))
}

func policyTool(_ name: String, parallel: Bool = true, approval: ToolApprovalPolicy = .automatic,
    execute: @escaping @Sendable (ToolInvocation) async throws -> ToolResultEnvelope = { .success(invocation: $0, text: "ok") }
) -> AgentRuntime.ToolRegistration {
    .init(definition: .init(name: name, description: name, inputSchema: .object([:]),
        approvalPolicy: approval, supportsParallelExecution: parallel), executor: .init { invocation, _ in try await execute(invocation) })
}

actor PolicyToolGate {
    let started: [String: XCTestExpectation]
    private var waiters: [String: CheckedContinuation<Void, Error>] = [:]
    private var released: Set<String> = []
    private var open = false
    private(set) var names: [String] = []
    private(set) var peak = 0
    private(set) var cancelled: Set<String> = []
    private var active = 0

    init(started: [String: XCTestExpectation]) { self.started = started }

    func enter(_ name: String) async throws {
        try Task.checkCancellation()
        active += 1
        peak = max(peak, active)
        names.append(name)
        started[name]?.fulfill()
        defer { active -= 1 }
        do {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                if !open, !released.contains(name) {
                    try await withCheckedThrowingContinuation { waiters[name] = $0 }
                }
            } onCancel: { Task { await self.cancel(name) } }
        } catch {
            cancelled.insert(name)
            throw error
        }
    }

    func release(_ name: String) {
        released.insert(name)
        waiters.removeValue(forKey: name)?.resume()
    }

    func releaseAll() {
        open = true
        let continuations = Array(waiters.values)
        waiters.removeAll()
        continuations.forEach { $0.resume() }
    }

    private func cancel(_ name: String) {
        waiters.removeValue(forKey: name)?.resume(throwing: CancellationError())
    }
}
