import CodexKit
import CodexKitUI
import Foundation
import Observation

enum MacDemoSection: String, CaseIterable, Identifiable {
    case assistant = "Assistant", structured = "Structured", memory = "Memory", runtime = "Runtime"
    var id: String { rawValue }
}

enum MacDemoAction: String, CaseIterable {
    case shipping, imported, streamed, saveMemory, rawMemory, queryMemory, previewMemory, captureMemory
    case instructions, compact, ephemeral, rename, planner, parallel, approval, travel, policyProbe, diagnostics
}

@MainActor
@Observable
final class MacDemoFeatures {
    var isBusy = false
    var error: String?
    var result = ""
    var structuredText = ""
    var structuredPayload = ""
    var partialCount = 0
    var memoryText = "I prefer concise answers with practical examples."
    var memoryQuery = "concise answers"
    var memories: [MemoryRecord] = []
    var memoryPreview = ""
    var threadTitle = ""
    var ephemeralPrompt = "Give a one-sentence summary of this conversation."
    var configuration = AgentThreadConfiguration(model: CodexModel.gpt56Sol, reasoningEffort: .low)
    let runtime: AgentRuntime
    let chat: AgentRuntimeStore
    let memory: any MemoryStoring
    private let sessions: ChatGPTSessionManager
    private let binding: ChatGPTSessionBinding
    private let diagnostics: MacDemoLogSink
    private var isActive = true
    @ObservationIgnored private var task: Task<Void, Never>?

    init(runtime: AgentRuntime, chat: AgentRuntimeStore, memory: any MemoryStoring,
         sessions: ChatGPTSessionManager, binding: ChatGPTSessionBinding, diagnostics: MacDemoLogSink) {
        self.runtime = runtime
        self.chat = chat
        self.memory = memory
        self.sessions = sessions
        self.binding = binding
        self.diagnostics = diagnostics
    }

    func cancel() {
        isActive = false
        task?.cancel()
        error = nil
        result = ""
        structuredText = ""
        structuredPayload = ""
        memories = []
        memoryPreview = ""
    }

    func stop() async {
        task?.cancel()
        await chat.interrupt()
    }

    func run(_ action: MacDemoAction, completion: @escaping @MainActor () async -> Void) {
        guard !isBusy, isActive else { return }
        task = Task {
            await execute(action)
            await completion()
        }
    }

    /// Shared by the UI and the signed app's integration tests.
    func execute(_ action: MacDemoAction) async {
        guard !isBusy, isActive else { return }
        isBusy = true
        error = nil
        defer { isBusy = false }
        do {
            try await validateSession()
            switch action {
            case .diagnostics: result = diagnostics.snapshot()
            case .shipping, .imported, .streamed: try await structured(action)
            case .saveMemory, .rawMemory, .queryMemory, .previewMemory, .captureMemory: try await manageMemory(action)
            default: try await runtimeExample(action)
            }
            try await validateSession()
        } catch is CancellationError { }
        catch { if isActive { self.error = error.localizedDescription } }
    }

    private func validateSession() async throws {
        try ensureActive()
        let current = try await sessions.requireSession()
        try ensureActive()
        guard current.binding == binding else { throw ChatGPTSessionError.accountChanged }
    }

    private func ensureActive() throws {
        try Task.checkCancellation()
        guard isActive else { throw CancellationError() }
    }

    private func newThread(_ title: String, skills: [String] = [], persona: AgentPersonaStack? = nil) async throws -> AgentThread {
        let thread = try await runtime.createThread(title: title, configuration: configuration,
            personaStack: persona, skillIDs: skills)
        try ensureActive()
        await chat.activateThread(id: thread.id)
        try ensureActive()
        return thread
    }

    private func activeThread() async throws -> AgentThread {
        if let thread = chat.activeThread { return thread }
        return try await newThread("Runtime example")
    }

    private func structured(_ action: MacDemoAction) async throws {
        structuredText = ""
        structuredPayload = ""
        partialCount = 0
        let thread = try await newThread("Structured: \(action.rawValue)", persona: MacDemoPersona.support.stack)
        switch action {
        case .shipping:
            let value = try await runtime.send(DemoStructuredOutputExamples.shippingReplyRequest(), in: thread.id,
                                              response: StructuredShippingReplyDraft.self)
            try ensureActive()
            structuredPayload = Self.json(["subject": value.subject, "reply": value.reply, "urgency": value.urgency.rawValue])
        case .imported:
            let value = try await runtime.send(DemoStructuredOutputExamples.importedSummaryRequest(), in: thread.id,
                                              response: StructuredImportedContentSummary.self)
            try ensureActive()
            structuredPayload = Self.json(["title": value.title, "keyPoints": value.keyPoints, "followUpAction": value.followUpAction])
        case .streamed:
            let stream = try await runtime.stream(DemoStructuredOutputExamples.streamedStructuredRequest(), in: thread.id,
                                                 response: StreamedStructuredDeliveryUpdate.self)
            var committed = false
            for try await event in stream {
                try ensureActive()
                switch event {
                case let .assistantMessageDelta(_, _, delta): structuredText += delta
                case let .structuredOutputPartial(value):
                    partialCount += 1
                    structuredPayload = Self.render(value)
                case let .structuredOutputCommitted(value):
                    committed = true
                    structuredPayload = Self.render(value)
                case let .turnFailed(error): throw error
                default: break
                }
            }
            guard committed else { throw AgentRuntimeError.structuredOutputMissing(formatName: StreamedStructuredDeliveryUpdate.responseFormat.name) }
        default: break
        }
        await chat.activateThread(id: thread.id)
        try ensureActive()
        result = "Typed result committed to the conversation."
    }

    private func manageMemory(_ action: MacDemoAction) async throws {
        let namespace = MacDemoRuntimeFactory.memoryNamespace
        switch action {
        case .saveMemory:
            let writer = MemoryWriter(store: memory, defaults: MacDemoRuntimeFactory.memoryDefaults)
            _ = try await writer.put(.init(summary: memoryText, importance: 0.8, tags: ["demo"]))
            try ensureActive()
            result = "Saved with MemoryWriter."
        case .rawMemory:
            try await memory.put(.init(namespace: namespace, scope: MacDemoRuntimeFactory.memoryScope,
                category: "preference", summary: memoryText, importance: 0.7, tags: ["raw", "demo"]))
            try ensureActive()
            result = "Saved a raw MemoryRecord."
        case .queryMemory:
            let matches = try await memory.query(.init(namespace: namespace, text: memoryQuery, limit: 10))
            try ensureActive()
            memories = matches.matches.map(\.record)
            result = "Found \(memories.count) matching memories."
            return
        case .previewMemory:
            let thread = try await activeThread()
            try await runtime.setMemoryContext(MacDemoRuntimeFactory.memoryContext, for: thread.id)
            let details = try await runtime.resolvedInstructionsPreviewDetails(for: thread.id, request: Request(text: memoryQuery))
            try ensureActive()
            memoryPreview = details.instructions
            result = "Memory is enabled for this conversation."
            await chat.activateThread(id: thread.id)
        case .captureMemory:
            let thread = try await activeThread()
            let captured = try await runtime.captureMemories(from: .threadHistory(), for: thread.id,
                options: .init(defaults: MacDemoRuntimeFactory.memoryDefaults, maxMemories: 3))
            try ensureActive()
            result = "Captured \(captured.records.count) memories from this conversation."
        default: break
        }
        let saved = try await memory.list(namespace: namespace, limit: 50)
        try ensureActive()
        memories = saved
    }

    private func runtimeExample(_ action: MacDemoAction) async throws {
        let thread: AgentThread
        switch action {
        case .parallel:
            thread = try await newThread("Parallel Lookups")
            await chat.send("Use demo_lookup_weather and demo_lookup_transport in the same batch, then summarize the sample results.")
            result = "Peak parallel tools: \(chat.peakConcurrentTools)."
        case .approval:
            thread = try await newThread("Tool Approval")
            await chat.send("Use demo_prepare_draft to prepare a sample support draft. Do not send anything.")
            result = "Approval example finished."
        case .travel:
            thread = try await newThread("Travel Planner Skill", skills: ["travel_planner"])
            await chat.send("Prepare a sample day plan for Sydney using the travel tool.")
            result = "Travel skill example finished."
        case .policyProbe:
            let normal = try await newThread("Policy Probe: General")
            await chat.send("Briefly describe a day in Sydney without using any tools.")
            let restricted = try await newThread("Policy Probe: Required Travel Tool", skills: ["travel_planner"])
            await chat.send("Briefly describe a day in Sydney without using any tools.")
            let messages = await runtime.messages(for: restricted.id)
            let toolUsed = messages.contains { $0.toolInteraction?.invocation.toolName == MacDemoToolName.travelPlanner.rawValue }
            result = "General conversation: \(normal.title ?? "General"). Required travel tool executed: \(toolUsed)."
            return
        default:
            thread = try await activeThread()
            switch action {
            case .instructions:
                let preview = try await runtime.resolvedInstructionsPreview(for: thread.id, request: Request(text: ephemeralPrompt))
                try ensureActive()
                result = preview
            case .compact:
                let state = try await runtime.compactThreadContext(id: thread.id)
                let usage = try await runtime.fetchThreadContextUsage(id: thread.id)
                try ensureActive()
                result = "Compaction generation \(state.generation). Effective context: \(usage?.effectiveEstimatedTokenCount ?? 0) estimated tokens."
            case .ephemeral:
                let before = await runtime.messages(for: thread.id).count
                let reply = try await runtime.send(Request(text: ephemeralPrompt, executionMode: .ephemeral), in: thread.id)
                let after = await runtime.messages(for: thread.id).count
                try ensureActive()
                result = "\(reply)\n\nTranscript messages: \(before) → \(after)."
            case .rename: try await runtime.setTitle(threadTitle, for: thread.id)
            case .planner: try await runtime.setPersonaStack(MacDemoPersona.planner.stack, for: thread.id)
            default: break
            }
        }
        try ensureActive()
        if let error = chat.lastError { throw MacDemoFeatureError(error) }
        if ![MacDemoAction.parallel, .approval, .travel].contains(action) {
            await chat.activateThread(id: thread.id)
        }
    }

    private static func json(_ value: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "Could not display the result." }
        return text
    }

    private static func render(_ value: StreamedStructuredDeliveryUpdate) -> String {
        json(["statusHeadline": value.statusHeadline, "customerPromise": value.customerPromise, "nextAction": value.nextAction])
    }
}

struct MacDemoFeatureError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
