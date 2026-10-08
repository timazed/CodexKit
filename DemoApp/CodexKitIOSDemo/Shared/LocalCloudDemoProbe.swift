#if DEBUG
import CodexKit
import Foundation

enum LocalCloudDemoProbe {
    struct Output: AgentStructuredOutput {
        let message: String
        static let responseFormat = AgentStructuredOutputFormat(name: "local-cloud-test",
            schema: .object(properties: ["message": .string()], required: ["message"]))
    }

    static func run(baseURL: URL, mode: LocalCloudDemoMode, session: ChatGPTSession?,
                    model: String = CodexModel.gpt56Sol.rawValue) async throws -> Output {
        _ = try LocalCloudDemoError.address(baseURL.absoluteString)
        let healthData = try await LocalCloudHTTP.data(for: URLRequest(url: baseURL.appendingPathComponent("health")))
        let health = try JSONDecoder().decode(Health.self, from: healthData)
        guard health.version == 1, health.status == "ok", health.mode == mode else { throw LocalCloudDemoError.mode }
        let credentials: ChatGPTSession
        switch mode {
        case .fixture:
            credentials = .init(accessToken: "synthetic-local-cloud", account: .init(
                id: "local-cloud-fixture", email: "fixture@example.test", plan: .unknown))
        case .live:
            guard let session, session.expiresAt.map({ $0 > Date() }) ?? true else { throw LocalCloudDemoError.authentication }
            credentials = session
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LocalCloudDemoTransport.self]
        let transport = URLSession(configuration: configuration)
        defer { transport.invalidateAndCancel() }
        let runtime = try AgentRuntime(configuration: .init(sessionProvider: Session(value: credentials),
            backend: CodexResponsesBackend(configuration: .init(baseURL: baseURL, model: model,
                reasoningEffort: .low, streamIdleTimeout: 100, requestRetryPolicy: .disabled), urlSession: transport),
            approvalPresenter: Approvals(), stateStore: InMemoryRuntimeStateStore()))
        let thread = try await runtime.createThread()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("local-cloud-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AgentStructuredRecoveryStore(directory: directory)
        let handle = try await runtime.prepareStructuredRecovery(Request(
            text: "Return a message confirming that this local cloud bridge test completed.", executionMode: .ephemeral),
            in: thread.id, response: Output.self, store: store, maximumAttempts: 1)
        let result = try await runtime.sendRecovering(handle, response: Output.self, store: store) { $0.number == 1 }
        let saved = try await runtime.sendRecovering(handle, response: Output.self, store: store) { _ in false }
        guard saved.message == result.message else { throw LocalCloudDemoError.response }
        return result
    }

    /// Debug harness exercises the same path as the UI with synthetic authentication only.
    static func verifyFromArguments() async {
        func argument(_ name: String) -> String? {
            guard let index = CommandLine.arguments.firstIndex(of: name), CommandLine.arguments.indices.contains(index + 1) else { return nil }
            return CommandLine.arguments[index + 1]
        }
        guard let path = argument("--verification-result") else { exit(2) }
        var report: [String: Any]
        do {
            let url = try LocalCloudDemoError.address(argument("--local-cloud-url") ?? "http://127.0.0.1:8787")
            let result = try await run(baseURL: url, mode: .fixture, session: nil)
            guard result.message == "Local cloud bridge OK" else { throw LocalCloudDemoError.response }
            let remote = try await RemoteExecutionDemoProbe.verify(baseURL: url)
            report = ["passed": true, "checks": ["Swift-prepared request crossed local HTTP and the TypeScript bridge",
                "Swift decoded the typed result and reopened its saved receipt"] + remote.checks,
                "remoteJobCount": remote.results.count, "simulatedPushDelivery": true]
        } catch { report = ["passed": false, "error": error.localizedDescription] }
        do { try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: path), options: .atomic) }
        catch { exit(2) }
        exit(report["passed"] as? Bool == true ? 0 : 1)
    }

    private struct Health: Decodable { let version: Int; let status: String; let mode: LocalCloudDemoMode }
    private struct Session: AgentSessionProviding {
        let value: ChatGPTSession
        func currentSession() async -> ChatGPTSession? { value }
    }
    private struct Approvals: ApprovalPresenting {
        func requestApproval(_ request: ApprovalRequest) async throws -> ApprovalDecision { .denied }
    }
}
#endif
