#if DEBUG
import CodexKit
import Foundation
import Observation

/// Runs the actual shared demo consumer with synthetic, chunked responses and isolated storage.
@MainActor
enum DemoStreamingVerification {
    static func run() async throws -> [String] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("StreamingDemo-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var checks: [String] = []
        for mode in ProgressiveOutputDemoMode.allCases {
            let url = directory.appendingPathComponent("\(mode.id).json")
            let gate = DemoStreamingGate()
            let backend = StreamingDemoBackend(source: DemoStreamingFixtures.source(mode), gate: gate)
            let runtime = try runtime(backend, store: FileRuntimeStateStore(url: url))
            let model = ProgressiveOutputDemoModel()
            model.start(mode, runtime: runtime, configuration: configuration)
            defer { model.cancel() }
            try await waitForPreview(model)
            try require(!model.isCommitted && model.isRunning, "\(mode): preview was promoted before commit")
            try require(mode != .json || model.units.isEmpty, "Raw JSON preview was decoded prematurely")
            guard let threadID = model.threadID else { throw Failure("Missing thread identity") }
            let provisional = try await runtime.fetchLatestStructuredOutputMetadata(id: threadID)
            try require(provisional == nil, "\(mode): preview was persisted")
            gate.release()
            await model.waitUntilFinished()
            try require(model.isCommitted && model.error == nil, "\(mode): \(model.error ?? model.status)")
            try require(model.context?.threadID == threadID, "\(mode): missing output identity")
            let units = model.units, rawText = model.rawText
            switch mode {
            case .text: try require(rawText == DemoStreamingFixtures.source(mode), "Text deltas were lost")
            case .records: try require(units.count == 3 && units.allSatisfy(\.isClosed), "Record cards were lost")
            case .xml:
                try require(
                    units.count == 3 && units[0].attributes.contains("priority=high")
                        && units[0].text == "Test & verify.", "XML text or attributes were lost")
            case .json: try require(units.count == 1 && units[0].title == "Boundaries", "JSON card was not decoded")
            }
            await runtime.deactivateThread(id: threadID)
            let restoreBackend = StreamingDemoBackend(source: "must not be requested")
            let reopened = try self.runtime(restoreBackend, store: FileRuntimeStateStore(url: url))
            _ = try await reopened.restore()
            _ = try await reopened.resumeThread(id: threadID)
            let restored = ProgressiveOutputDemoModel()
            restored.restore(mode, threadID: threadID, runtime: reopened)
            await restored.waitUntilFinished()
            try require(
                restored.restored && restored.error == nil && restored.units == units && restored.rawText == rawText,
                "\(mode): saved output did not reload")
            try require(
                restored.context == model.context && restored.previewEvents == 0,
                "\(mode): restoration retained old presentation state")
            let requests = await restoreBackend.requestCount
            try require(requests == 0, "\(mode): restoration made a model request")
            checks.append("streaming \(mode.rawValue): provisional events, commit, and saved-output restoration")
        }

        for mode in [ProgressiveOutputDemoMode.records, .xml] {
            let invalid =
                mode == .records
                ? DemoStreamingFixtures.record + "\n"
                : DemoStreamingFixtures.source(.xml).replacingOccurrences(of: "high", with: "invalid")
            let backend = StreamingDemoBackend(source: invalid)
            let runtime = try runtime(backend)
            let model = ProgressiveOutputDemoModel()
            model.start(mode, runtime: runtime, configuration: configuration)
            await model.waitUntilFinished()
            try require(
                !model.isCommitted && model.previewEvents > 0 && model.error != nil,
                "Invalid \(mode) did not fail after previews")
            guard let threadID = model.threadID else { throw Failure("Missing invalid-output thread") }
            let stored = try await runtime.fetchLatestStructuredOutputMetadata(id: threadID)
            try require(stored == nil, "Invalid \(mode) was saved")
        }
        checks.append("record count and XML XSD failures leave previews uncommitted")

        let backend = StreamingDemoBackend(source: DemoStreamingFixtures.source(.records), gate: DemoStreamingGate())
        let runtime = try runtime(backend)
        let model = ProgressiveOutputDemoModel()
        model.start(.records, runtime: runtime, configuration: configuration)
        defer { model.cancel() }
        try await waitForPreview(model)
        model.cancel()
        await model.waitUntilFinished()
        guard case .cancelled = model.result else { throw Failure("Cancellation did not produce a cancelled result") }
        try require(!model.isBusy, "Cancellation left the demo running")
        guard let threadID = model.threadID else { throw Failure("Missing cancelled-output thread") }
        let stored = try await runtime.fetchLatestStructuredOutputMetadata(id: threadID)
        try require(stored == nil, "Cancelled preview was saved")
        checks.append("streaming demo cancellation stops the execution without committing previews")
        return checks
    }

    private static let configuration = AgentThreadConfiguration(model: CodexModel.gpt56Sol, reasoningEffort: .low)

    private static func runtime(
        _ backend: StreamingDemoBackend,
        store: any RuntimeStateStoring = InMemoryRuntimeStateStore()
    ) throws -> AgentRuntime {
        try AgentRuntime(
            configuration: .init(
                sessionProvider: Session(), backend: backend,
                approvalPresenter: Approvals(), stateStore: store, maximumBufferedEvents: 1,
                turnLimits: .init(maximumDuration: 5)))
    }

    static func waitForPreview(_ model: ProgressiveOutputDemoModel) async throws {
        let changes = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observePreview(model, continuation: changes.continuation)
        for await _ in changes.stream { break }
        try require(hasPreview(model), "No preview arrived: \(model.error ?? model.status)")
    }

    private static func observePreview(
        _ model: ProgressiveOutputDemoModel, continuation: AsyncStream<Void>.Continuation
    ) {
        if hasPreview(model) || !model.isBusy {
            continuation.yield(())
            continuation.finish()
            return
        }
        withObservationTracking {
            _ = hasPreview(model)
            _ = model.isBusy
        } onChange: {
            Task { @MainActor in observePreview(model, continuation: continuation) }
        }
    }

    private static func hasPreview(_ model: ProgressiveOutputDemoModel) -> Bool {
        guard model.previewEvents > 0 else { return false }
        switch model.mode {
        case .records, .xml: return model.units.count == 3 && model.units.allSatisfy(\.isClosed)
        case .text, .json: return !model.rawText.isEmpty
        }
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message) }
    }
    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
    private struct Session: AgentSessionProviding {
        func currentSession() async -> ChatGPTSession? {
            .init(
                accessToken: "synthetic-streaming-demo",
                account: .init(id: "streaming-demo", email: "demo@example.invalid", plan: .unknown))
        }
    }
    private struct Approvals: ApprovalPresenting {
        func requestApproval(_ request: ApprovalRequest) async throws -> ApprovalDecision { .denied }
    }
}

enum DemoStreamingFixtures {
    static let record = #"{"id":1,"title":"Boundaries","text":"Test & verify."}"#

    static func source(_ mode: ProgressiveOutputDemoMode) -> String {
        switch mode {
        case .text: "Test boundaries. Check errors. Verify cancellation."
        case .records:
            (1...3).map { record.replacingOccurrences(of: "\"id\":1", with: "\"id\":\($0)") }.joined(separator: "\n")
                + "\n"
        case .json: record
        case .xml:
            "<response>" + (1...3).map { "<tip id=\"\($0)\" priority=\"high\">Test &amp; verify.</tip>" }.joined()
                + "</response>"
        }
    }
}

/// A one-shot, cancellation-aware gate; no timing assumptions or polling.
final class DemoStreamingGate: Sendable {
    private let channel = AsyncStream<Void>.makeStream()

    func release() {
        channel.continuation.finish()
    }

    func wait() async throws {
        for await _ in channel.stream {}
        try Task.checkCancellation()
    }
}

actor StreamingDemoBackend: AgentBackend {
    let source: String
    let chunkDelay: Duration
    let gate: DemoStreamingGate?
    private(set) var requestCount = 0

    init(source: String, chunkDelay: Duration = .zero, gate: DemoStreamingGate? = nil) {
        self.source = source
        self.chunkDelay = chunkDelay
        self.gate = gate
    }
    func createThread(session: ChatGPTSession) async throws -> AgentThread { .init(id: UUID().uuidString) }
    func resumeThread(id: String, session: ChatGPTSession) async throws -> AgentThread { .init(id: id) }
    func beginTurn(
        thread: AgentThread, history: [AgentMessage], message: Request, instructions: String,
        responseFormat: AgentStructuredOutputFormat?, streamedStructuredOutput: AgentStreamedStructuredOutputRequest?,
        tools: [ToolDefinition], session: ChatGPTSession
    ) async throws -> AgentTurnStream {
        requestCount += 1
        let channel = AsyncThrowingStream<AgentBackendEvent, Error>.makeStream()
        let task = Task {
            do {
                let turn = AgentTurn(id: UUID().uuidString, threadID: thread.id)
                let messageID = UUID().uuidString
                channel.continuation.yield(.turnStarted(turn))
                let characters = Array(source)
                for start in stride(from: 0, to: characters.count, by: 11) {
                    if chunkDelay > .zero { try await Task.sleep(for: chunkDelay) }
                    let text = String(characters[start..<min(start + 11, characters.count)])
                    channel.continuation.yield(
                        .assistantContentDelta(
                            .init(
                                threadID: thread.id,
                                turnID: turn.id, messageID: messageID, contentIndex: 0, phase: .finalAnswer, text: text)
                        ))
                }
                try await gate?.wait()
                try Task.checkCancellation()
                channel.continuation.yield(
                    .assistantMessageCompleted(
                        .init(
                            id: messageID,
                            threadID: thread.id, role: .assistant, text: source, phase: .finalAnswer)))
                channel.continuation.yield(.turnCompleted(.init(threadID: thread.id, turnID: turn.id)))
                channel.continuation.finish()
            } catch { channel.continuation.finish(throwing: error) }
        }
        channel.continuation.onTermination = { _ in task.cancel() }
        return .init(events: channel.stream, steer: nil, interrupt: { task.cancel() })
    }
}
#endif
