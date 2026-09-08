#if DEBUG
import CodexKit
import CodexKitSQLite
import CodexKitRealm
import CodexKitUI
import Foundation

/// Opt-in device verification. Creates and removes its own adapter-test threads; writes its own report.
@MainActor
enum DemoRuntimeVerification {
    private static var hasRun = false

    static func runIfRequested() async {
        guard CommandLine.arguments.contains("--verify-runtime"), !hasRun else { return }
        hasRun = true
        var report = ["startedAt": ISO8601DateFormatter().string(from: Date()),
            "runID": ProcessInfo.processInfo.environment["CODEXKIT_VERIFICATION_RUN_ID"] ?? UUID().uuidString]
        for adapter in ["sqlite", "realm"] {
            do {
                try await verifyLocalAdapter(adapter)
                report[adapter] = "passed"
            } catch { report[adapter] = failureCode(error) }
        }
        report["localAdapters"] = report["sqlite"] == "passed" && report["realm"] == "passed"
            ? "passed" : "failed: local_adapter_verification"
        if CommandLine.arguments.contains("--verify-local-only") {
            report["liveProvider"] = "skipped: local_only"
        } else {
            do { report["liveProvider"] = try await verifyLiveProvider() }
            catch { report["liveProvider"] = failureCode(error) }
        }
        report["finishedAt"] = ISO8601DateFormatter().string(from: Date())
        let url = URL.documentsDirectory.appendingPathComponent("CodexKitVerification.json")
        do {
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
            print("CODEXKIT_VERIFICATION_FINISHED")
        } catch { print("CODEXKIT_VERIFICATION_REPORT_FAILED") }
    }

    private static func verifyLiveProvider() async throws -> String {
        let store = KeychainSessionSecureStore(service: "AssistantRuntimeDemoApp.ChatGPTSession", account: "AssistantRuntimeDemoApp")
        if let session = try store.loadSession(), !session.requiresRefresh() {
            let runtime = try AgentRuntime(configuration: .init(sessionProvider: VerificationSession(session: session),
                backend: CodexResponsesBackend(configuration: .init(enableWebSearch: false, enableImageGeneration: false,
                    requestRetryPolicy: .disabled, maximumModelPasses: 1, maximumResponseBytes: 1_024 * 1_024)),
                approvalPresenter: VerificationApprovals(), stateStore: InMemoryRuntimeStateStore(),
                turnLimits: .init(maximumToolCalls: 0, maximumDuration: 60),
                backgroundActivityProvider: IOSBackgroundActivityProvider()))
            let thread = try await runtime.createThread()
            let text = try await runtime.send(Request(text: "Reply with exactly OK. Do not use tools.", executionMode: .ephemeral), in: thread.id)
            guard !text.isEmpty else { throw VerificationError.missingText }
            let value = try await runtime.send(Request(text: "Return value set to ok. Do not use tools.", executionMode: .ephemeral),
                in: thread.id, response: VerificationOutput.self)
            guard value.value == "ok" else { throw VerificationError.invalidOutput }
            return "passed"
        } else { return "skipped: no_current_session" }
    }

    private static func makeLocalRuntime(adapter: String) throws -> AgentRuntime {
        let store: any RuntimeStateStoring = adapter == "sqlite"
            ? try SQLiteRuntimeStateStore() : try RealmRuntimeStateStore()
        let session = ChatGPTSession(accessToken: "local-verification",
            account: .init(id: "local-verification", email: "verification@example.com", plan: .unknown))
        return try AgentRuntime(configuration: .init(sessionProvider: VerificationSession(session: session),
            backend: VerificationBackend(), approvalPresenter: VerificationApprovals(), stateStore: store,
            maximumBufferedEvents: 1, turnLimits: .init(maximumDuration: 5),
            threadActivationPolicy: .init(maximumMessageCount: 4, maximumHistoryRecordCount: 1),
            backgroundActivityProvider: IOSBackgroundActivityProvider()))
    }

    private static func verifyLocalAdapter(_ adapter: String) async throws {
        var runtime = try makeLocalRuntime(adapter: adapter)
        let thread = try await runtime.createThread(title: "CodexKit verification (temporary)")
        do {
            let execution = try await runtime.start(Request(text: "Local verification"), in: thread.id)
            try await execution.waitUntilReady()
            var completed = false
            for try await event in execution.events { if case .turnCompleted = event { completed = true } }
            guard completed else { throw VerificationError.missingCompletion }
            let value = try await runtime.send(Request(text: "Structured verification"), in: thread.id, response: VerificationOutput.self)
            guard value.value == "ok" else { throw VerificationError.invalidOutput }
            await runtime.deactivateThread(id: thread.id)
            runtime = try makeLocalRuntime(adapter: adapter)
            _ = try await runtime.restore()
            _ = try await runtime.resumeThread(id: thread.id)
            let restored = await runtime.messages(for: thread.id)
            guard restored.contains(where: { $0.text == "Local verification" }),
                  restored.contains(where: { $0.text == "{\"value\":\"ok\"}" }) else {
                throw VerificationError.persistenceFailed
            }
            let transient = try await runtime.start(Request(text: "Cancellation verification", executionMode: .ephemeral), in: thread.id)
            transient.cancel()
            do {
                for try await _ in transient.events {}
                throw VerificationError.cancellationFailed
            } catch is CancellationError {}
            try await runtime.deleteThread(id: thread.id)
        } catch {
            try? await runtime.deleteThread(id: thread.id)
            throw error
        }
    }
    private static func failureCode(_ error: Error) -> String {
        "failed: " + ((error as? AgentRuntimeError)?.code ?? "verification_failed")
    }
}

private enum VerificationError: Error { case missingText, invalidOutput, missingCompletion, cancellationFailed, persistenceFailed }

private struct VerificationApprovals: ApprovalPresenting {
    func requestApproval(_ request: ApprovalRequest) async throws -> ApprovalDecision { .denied }
}

private struct VerificationSession: AgentSessionProviding {
    let session: ChatGPTSession
    func currentSession() async -> ChatGPTSession? { session }
}

private struct VerificationOutput: AgentStructuredOutput {
    let value: String
    static let responseFormat = AgentStructuredOutputFormat(name: "verification",
        schema: .object(properties: ["value": .string(enum: ["ok"])], required: ["value"], additionalProperties: false))
}

private struct VerificationBackend: AgentBackend {
    func createThread(session: ChatGPTSession) async throws -> AgentThread { .init(id: UUID().uuidString) }
    func resumeThread(id: String, session: ChatGPTSession) async throws -> AgentThread { .init(id: id) }
    func beginTurn(thread: AgentThread, history: [AgentMessage], message: Request, instructions: String,
        responseFormat: AgentStructuredOutputFormat?, streamedStructuredOutput: AgentStreamedStructuredOutputRequest?,
        tools: [ToolDefinition], session: ChatGPTSession) async throws -> AgentTurnStream {
        let turn = AgentTurn(id: UUID().uuidString, threadID: thread.id)
        let text = responseFormat == nil ? "ok" : "{\"value\":\"ok\"}"
        return AgentTurnStream(events: AsyncThrowingStream { continuation in
            continuation.yield(.turnStarted(turn))
            continuation.yield(.assistantMessageCompleted(.init(threadID: thread.id, role: .assistant, text: text)))
            if streamedStructuredOutput != nil {
                continuation.yield(.structuredOutputCommitted(.object(["value": .string("ok")])))
            }
            continuation.yield(.turnCompleted(.init(threadID: thread.id, turnID: turn.id)))
            continuation.finish()
        })
    }
}
#endif
