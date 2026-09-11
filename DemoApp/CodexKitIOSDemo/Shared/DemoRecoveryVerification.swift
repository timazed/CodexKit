#if DEBUG
import CodexKit
import Foundation

/// Uses the real Responses backend with an offline transport. No account credentials or live requests.
enum DemoRecoveryVerification {
    static func run(directory: URL, smoke: Bool = false) async throws -> [String] {
        try? FileManager.default.removeItem(at: directory)
        let store = AgentStructuredRecoveryStore(directory: directory)
        var checks: [String] = []
        let scenarios = smoke ? [] : [("before output", created), ("mid response", created + delta),
                                     ("lost terminal event", created + message)]
        for (name, prefix) in scenarios {
            // Baseline: the existing send API with SDK retries disabled fails after one interrupted POST.
            DemoRecoveryTransport.configure([prefix, message + completed])
            let baseline = try runtime()
            let baselineThread = try await baseline.createThread()
            do {
                _ = try await baseline.send(Request(text: "Synthetic preparation", executionMode: .ephemeral),
                    in: baselineThread.id, response: Output.self)
                throw Failure("Baseline unexpectedly completed: \(name)")
            } catch let error as AgentRuntimeError {
                try require(error.knownCode == .responsesStreamDisconnected, "Unexpected baseline error")
            }
            try require(DemoRecoveryTransport.count == 1, "Baseline request count")

            DemoRecoveryTransport.configure([prefix, message + completed])
            let recovering = try runtime()
            let handle = try await prepare(recovering, store: store)
            let value = try await recovering.sendRecovering(handle, response: Output.self, store: store) {
                $0.number <= 3
            }
            try require(value.value == "ok" && DemoRecoveryTransport.count == 2, "Replacement did not complete: \(name)")
            let status = try await recovering.structuredRecoveryStatus(handle, store: store)
            try require(status.state == .completed && status.attemptsUsed == 2, "Incorrect saved budget")
            checks.append("\(name): baseline fails with 1 POST; recovery succeeds with 2 POSTs")
            try await recovering.acknowledgeStructuredRecovery(handle, store: store)
        }

        if !smoke {
            DemoRecoveryTransport.configure([created, created, created, message + completed])
            let bounded = try runtime()
            let boundedHandle = try await prepare(bounded, store: store)
            do {
                _ = try await bounded.sendRecovering(boundedHandle, response: Output.self, store: store) { _ in true }
                throw Failure("Exhausted request succeeded")
            } catch let failure as AgentRuntimeError {
                try require(failure.interruption?.outcome == .disconnected, "Incorrect exhaustion failure")
            }
            try require(DemoRecoveryTransport.count == 3, "Exceeded three-attempt budget")
            checks.append("repeated drops stop after exactly 3 POSTs")
        }

        DemoRecoveryTransport.configure([created + delta], hold: true)
        let cancelled = try runtime()
        let cancelledHandle = try await prepare(cancelled, store: store)
        let task = Task { try await cancelled.sendRecovering(cancelledHandle, response: Output.self, store: store) { _ in true } }
        try await waitForCursor(cancelledHandle, store: store)
        task.cancel()
        do { _ = try await task.value; throw Failure("Cancelled generation returned output") }
        catch is CancellationError {}
        let cancelledStatus = try await cancelled.structuredRecoveryStatus(cancelledHandle, store: store)
        try require(cancelledStatus.state == .cancelled && DemoRecoveryTransport.count == 1, "Cancellation retried")
        checks.append("cancellation after output saves cancelled state with exactly 1 POST")

        // Leave a completed receipt unacknowledged. The harness terminates this process and reopens it.
        DemoRecoveryTransport.configure([created + message + completed])
        let firstProcess = try runtime()
        let handle = try await prepare(firstProcess, store: store)
        try JSONEncoder().encode(handle).write(to: directory.appendingPathComponent("handle.json"), options: .atomic)
        _ = try await firstProcess.sendRecovering(handle, response: Output.self, store: store) { _ in true }
        try require(DemoRecoveryTransport.count == 1, "Receipt preparation made extra requests")
        checks.append("completed receipt saved before host acknowledgement for next-process recovery")
        return checks
    }

    static func reopen(directory: URL) async throws -> [String] {
        DemoRecoveryTransport.configure([])
        let store = AgentStructuredRecoveryStore(directory: directory)
        let handle = try JSONDecoder().decode(AgentStructuredRecoveryHandle.self,
            from: Data(contentsOf: directory.appendingPathComponent("handle.json")))
        let reopened = try runtime()
        let value = try await reopened.sendRecovering(handle, response: Output.self, store: store) { _ in
            throw Failure("Cold receipt retrieval requested a generation attempt")
        }
        try require(value.value == "ok" && DemoRecoveryTransport.count == 0, "Cold reopen did not return saved output")
        try await reopened.acknowledgeStructuredRecovery(handle, store: store)
        return ["new app process retrieves validated result with 0 POSTs and 0 authorizations"]
    }

    private static func prepare(_ runtime: AgentRuntime, store: AgentStructuredRecoveryStore) async throws -> AgentStructuredRecoveryHandle {
        let thread = try await runtime.createThread()
        return try await runtime.prepareStructuredRecovery(Request(text: "Synthetic preparation", executionMode: .ephemeral),
            in: thread.id, response: Output.self, store: store, maximumAttempts: 3)
    }

    private static func runtime() throws -> AgentRuntime {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DemoRecoveryTransport.self]
        return try AgentRuntime(configuration: .init(sessionProvider: Session(),
            backend: CodexResponsesBackend(configuration: .init(requestRetryPolicy: .disabled),
                urlSession: URLSession(configuration: configuration)), approvalPresenter: Approvals(),
            stateStore: InMemoryRuntimeStateStore(), turnLimits: .init(maximumDuration: nil)))
    }

    private static func waitForCursor(_ handle: AgentStructuredRecoveryHandle, store: AgentStructuredRecoveryStore) async throws {
        let url = store.directory.appendingPathComponent(handle.id.uuidString + ".json")
        for _ in 0..<300 {
            if let data = try? Data(contentsOf: url),
               let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               object["lastSequenceNumber"] as? Int == 1 { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw Failure("Timed out waiting for controlled partial output")
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message) }
    }
    private struct Failure: Error, LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
    private struct Output: AgentStructuredOutput {
        let value: String
        static let responseFormat = AgentStructuredOutputFormat(name: "recovery-demo",
            schema: .object(properties: ["value": .string(enum: ["ok"])], required: ["value"]))
    }
    private struct Session: AgentSessionProviding {
        func currentSession() async -> ChatGPTSession? {
            .init(accessToken: "synthetic-fixture", account: .init(id: "recovery-fixture", email: "fixture@example.com", plan: .unknown))
        }
    }
    private struct Approvals: ApprovalPresenting {
        func requestApproval(_ request: ApprovalRequest) async throws -> ApprovalDecision { .denied }
    }
    private static let created = "data: {\"type\":\"response.created\",\"sequence_number\":0,\"response\":{\"id\":\"original\"}}\n\n"
    private static let delta = "data: {\"type\":\"response.output_text.delta\",\"sequence_number\":1,\"delta\":\"discard this partial\"}\n\n"
    private static let message = "data: {\"type\":\"response.output_item.done\",\"sequence_number\":2,\"item\":{\"id\":\"message\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"{\\\"value\\\":\\\"ok\\\"}\"}]}}\n\n"
    private static let completed = "data: {\"type\":\"response.completed\",\"sequence_number\":3,\"response\":{\"id\":\"completed\"}}\n\n"
}

private final class DemoRecoveryTransport: URLProtocol, @unchecked Sendable {
    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var replies: [String] = []
        var count = 0
        var hold = false
    }
    private static let storage = Storage()
    static var count: Int { storage.lock.withLock { storage.count } }
    static func configure(_ replies: [String], hold: Bool = false) {
        storage.lock.withLock { storage.replies = replies; storage.count = 0; storage.hold = hold }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply: (String?, Bool) = Self.storage.lock.withLock {
            Self.storage.count += 1
            return (Self.storage.replies.isEmpty ? nil : Self.storage.replies.removeFirst(), Self.storage.hold)
        }
        guard let body = reply.0 else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        if !reply.1 { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() {}
}
#endif
