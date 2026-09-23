#if DEBUG
import CodexKit
import Foundation

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
            let backend = StreamingDemoBackend(source: source(mode))
            let runtime = try runtime(backend, store: FileRuntimeStateStore(url: url))
            let model = ProgressiveOutputDemoModel()
            let task = Task { await model.run(mode, runtime: runtime, configuration: configuration) }
            defer { task.cancel() }
            try await waitForPreview(model)
            try require(model.phase == .streaming, "\(mode): preview was promoted before commit")
            try require(mode != .json || model.units.isEmpty, "Raw JSON preview was decoded prematurely")
            guard let threadID = model.threadID else { throw Failure("Missing thread identity") }
            let provisional = try await runtime.fetchLatestStructuredOutputMetadata(id: threadID)
            try require(provisional == nil, "\(mode): preview was persisted")
            await backend.release()
            await task.value
            try require(model.phase == .committed && model.error == nil, "\(mode): \(model.error ?? model.status)")
            try require(model.context?.threadID == threadID, "\(mode): missing output identity")
            let units = model.units, rawText = model.rawText
            switch mode {
            case .text: try require(rawText == source(mode), "Text deltas were lost")
            case .records: try require(units.count == 3 && units.allSatisfy(\.isClosed), "Record cards were lost")
            case .xml:
                try require(units.count == 3 && units[0].attributes.contains("priority=high")
                    && units[0].text == "Test & verify.", "XML text or attributes were lost")
            case .json: try require(units.count == 1 && units[0].title == "Boundaries", "JSON card was not decoded")
            }
            await runtime.deactivateThread(id: threadID)
            let reopened = try self.runtime(StreamingDemoBackend(source: "must not be requested"), store: FileRuntimeStateStore(url: url))
            _ = try await reopened.restore()
            _ = try await reopened.resumeThread(id: threadID)
            await model.reload(runtime: reopened)
            try require(model.restored && model.error == nil && model.units == units && model.rawText == rawText,
                        "\(mode): saved output did not reload")
            checks.append("streaming \(mode.rawValue): provisional events, commit, and saved-output restoration")
        }

        for mode in [ProgressiveOutputDemoMode.records, .xml] {
            let invalid = mode == .records ? record + "\n" : source(.xml).replacingOccurrences(of: "high", with: "invalid")
            let backend = StreamingDemoBackend(source: invalid)
            await backend.release()
            let runtime = try runtime(backend)
            let model = ProgressiveOutputDemoModel()
            await model.run(mode, runtime: runtime, configuration: configuration)
            try require(model.phase == .failed && model.previewEvents > 0 && model.error != nil,
                        "Invalid \(mode) did not fail after previews")
            let stored = try await runtime.fetchLatestStructuredOutputMetadata(id: model.threadID!)
            try require(stored == nil, "Invalid \(mode) was saved")
        }
        checks.append("record count and XML XSD failures leave previews uncommitted")

        let backend = StreamingDemoBackend(source: source(.records))
        let runtime = try runtime(backend)
        let model = ProgressiveOutputDemoModel()
        let task = Task { await model.run(.records, runtime: runtime, configuration: configuration) }
        defer { task.cancel() }
        try await waitForPreview(model)
        task.cancel()
        await task.value
        try require(model.phase == .cancelled && !model.isRunning, "Cancellation left the demo running or committed")
        let stored = try await runtime.fetchLatestStructuredOutputMetadata(id: model.threadID!)
        try require(stored == nil, "Cancelled preview was saved")
        checks.append("streaming demo cancellation stops the execution without committing previews")
        return checks
    }

    private static let configuration = AgentThreadConfiguration(model: CodexModel.gpt56Sol, reasoningEffort: .low)
    static let record = #"{"id":1,"title":"Boundaries","text":"Test & verify."}"#
    static func source(_ mode: ProgressiveOutputDemoMode) -> String {
        switch mode {
        case .text: "Test boundaries. Check errors. Verify cancellation."
        case .records: (1...3).map { record.replacingOccurrences(of: "\"id\":1", with: "\"id\":\($0)") }.joined(separator: "\n") + "\n"
        case .json: record
        case .xml: "<response>" + (1...3).map { "<tip id=\"\($0)\" priority=\"high\">Test &amp; verify.</tip>" }.joined() + "</response>"
        }
    }

    private static func runtime(_ backend: StreamingDemoBackend,
                                store: any RuntimeStateStoring = InMemoryRuntimeStateStore()) throws -> AgentRuntime {
        try AgentRuntime(configuration: .init(sessionProvider: Session(), backend: backend,
            approvalPresenter: Approvals(), stateStore: store, maximumBufferedEvents: 1,
            turnLimits: .init(maximumDuration: 5)))
    }

    private static func waitForPreview(_ model: ProgressiveOutputDemoModel) async throws {
        for _ in 0..<400 {
            let ready: Bool
            switch model.mode {
            case .records, .xml: ready = model.units.count == 3 && model.units.allSatisfy(\.isClosed)
            case .text, .json: ready = !model.rawText.isEmpty
            }
            if model.previewEvents > 0 && ready { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw Failure("No preview arrived: \(model.error ?? model.status)")
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
            .init(accessToken: "synthetic-streaming-demo", account: .init(id: "streaming-demo", email: "demo@example.invalid", plan: .unknown))
        }
    }
    private struct Approvals: ApprovalPresenting {
        func requestApproval(_ request: ApprovalRequest) async throws -> ApprovalDecision { .denied }
    }
}

actor StreamingDemoBackend: AgentBackend {
    let source: String
    let chunkDelay: Duration
    private var released = false
    init(source: String, chunkDelay: Duration = .zero) { self.source = source; self.chunkDelay = chunkDelay }
    func release() { released = true }
    private func waitForRelease() async throws {
        while !released { try await Task.sleep(for: .milliseconds(5)) }
        try Task.checkCancellation()
    }
    func createThread(session: ChatGPTSession) async throws -> AgentThread { .init(id: UUID().uuidString) }
    func resumeThread(id: String, session: ChatGPTSession) async throws -> AgentThread { .init(id: id) }
    func beginTurn(thread: AgentThread, history: [AgentMessage], message: Request, instructions: String,
                   responseFormat: AgentStructuredOutputFormat?, streamedStructuredOutput: AgentStreamedStructuredOutputRequest?,
                   tools: [ToolDefinition], session: ChatGPTSession) async throws -> AgentTurnStream {
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
                    channel.continuation.yield(.assistantContentDelta(.init(threadID: thread.id,
                        turnID: turn.id, messageID: messageID, contentIndex: 0, phase: .finalAnswer, text: text)))
                }
                try await waitForRelease()
                channel.continuation.yield(.assistantMessageCompleted(.init(id: messageID,
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
