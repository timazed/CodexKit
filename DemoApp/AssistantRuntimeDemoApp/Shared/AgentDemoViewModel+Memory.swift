import CodexKit
import Foundation

@MainActor
extension AgentDemoViewModel {
    func runAutomaticPolicyMemoryDemo() async {
        guard session != nil else {
            lastError = "Sign in before running policy-based memory capture."
            return
        }
        guard !isRunningMemoryDemo else {
            return
        }

        isRunningMemoryDemo = true
        lastError = nil
        defer {
            isRunningMemoryDemo = false
        }

        do {
            let thread = try await runtime.createThread(
                title: "Memory Demo: Automatic Policy",
                memoryContext: AgentMemoryContext(
                    namespace: DemoMemoryExamples.namespace,
                    scopes: [DemoMemoryExamples.healthCoachScope],
                    kinds: ["preference"]
                )
            )
            _ = try await runtime.sendMessage(
                UserMessageRequest(text: DemoMemoryExamples.automaticPolicyPrompt),
                in: thread.id
            )

            let store = try SQLiteMemoryStore(url: AgentDemoRuntimeFactory.defaultMemoryURL())
            let result = try await store.query(
                MemoryQuery(
                    namespace: DemoMemoryExamples.namespace,
                    scopes: [DemoMemoryExamples.healthCoachScope],
                    text: "direct blunt steps",
                    limit: 4,
                    maxCharacters: 800
                )
            )

            automaticPolicyMemoryResult = AutomaticPolicyMemoryDemoResult(
                threadID: thread.id,
                threadTitle: thread.title ?? "Memory Demo: Automatic Policy",
                prompt: DemoMemoryExamples.automaticPolicyPrompt,
                records: result.matches.map(\.record)
            )
            threads = await runtime.threads()
        } catch {
            reportError(error)
        }
    }

    func runAutomaticMemoryDemo() async {
        guard session != nil else {
            lastError = "Sign in before running automatic memory capture."
            return
        }
        guard !isRunningMemoryDemo else {
            return
        }

        isRunningMemoryDemo = true
        lastError = nil
        defer {
            isRunningMemoryDemo = false
        }

        do {
            let thread = try await runtime.createThread(
                title: "Memory Demo: Automatic Capture",
                memoryContext: DemoMemoryExamples.previewContext
            )
            let capture = try await runtime.captureMemories(
                from: .text(DemoMemoryExamples.automaticCaptureTranscript),
                for: thread.id,
                options: .init(
                    defaults: DemoMemoryExamples.guidedDefaults,
                    maxMemories: 3
                )
            )
            automaticMemoryResult = AutomaticMemoryDemoResult(
                threadID: thread.id,
                threadTitle: thread.title ?? "Memory Demo: Automatic Capture",
                capture: capture
            )
            threads = await runtime.threads()
        } catch {
            reportError(error)
        }
    }

    func runGuidedMemoryDemo() async {
        guard !isRunningMemoryDemo else {
            return
        }

        isRunningMemoryDemo = true
        lastError = nil
        defer {
            isRunningMemoryDemo = false
        }

        do {
            let writer = try await runtime.memoryWriter(defaults: DemoMemoryExamples.guidedDefaults)
            let record = try await writer.upsert(DemoMemoryExamples.guidedDraft)
            let diagnostics = try await writer.diagnostics()

            guidedMemoryResult = GuidedMemoryDemoResult(
                record: record,
                diagnostics: diagnostics
            )
        } catch {
            reportError(error)
        }
    }

    func runRawMemoryDemo() async {
        guard !isRunningMemoryDemo else {
            return
        }

        isRunningMemoryDemo = true
        lastError = nil
        defer {
            isRunningMemoryDemo = false
        }

        do {
            let store = try SQLiteMemoryStore(url: AgentDemoRuntimeFactory.defaultMemoryURL())
            try await store.upsert(
                DemoMemoryExamples.rawRecord,
                dedupeKey: DemoMemoryExamples.rawRecord.dedupeKey ?? DemoMemoryExamples.rawRecord.id
            )
            let diagnostics = try await store.diagnostics(namespace: DemoMemoryExamples.namespace)

            rawMemoryResult = RawMemoryDemoResult(
                record: DemoMemoryExamples.rawRecord,
                diagnostics: diagnostics
            )
        } catch {
            reportError(error)
        }
    }

    func runMemoryPreviewDemo() async {
        guard !isRunningMemoryDemo else {
            return
        }

        isRunningMemoryDemo = true
        lastError = nil
        defer {
            isRunningMemoryDemo = false
        }

        do {
            let result: MemoryQueryResult
            var previewThreadID: String?
            var previewThreadTitle: String?

            if session != nil {
                let thread = try await runtime.createThread(
                    title: "Memory Demo: Prompt Injection",
                    memoryContext: DemoMemoryExamples.previewContext
                )
                previewThreadID = thread.id
                previewThreadTitle = thread.title
                result = try await runtime.memoryQueryPreview(
                    for: thread.id,
                    request: UserMessageRequest(text: DemoMemoryExamples.previewRequestText)
                ) ?? MemoryQueryResult(matches: [], truncated: false)
                threads = await runtime.threads()
            } else {
                let store = try SQLiteMemoryStore(url: AgentDemoRuntimeFactory.defaultMemoryURL())
                result = try await store.query(
                    MemoryQuery(
                        namespace: DemoMemoryExamples.namespace,
                        scopes: DemoMemoryExamples.previewContext.scopes,
                        text: DemoMemoryExamples.previewRequestText,
                        limit: DemoMemoryExamples.previewBudget.maxItems,
                        maxCharacters: DemoMemoryExamples.previewBudget.maxCharacters
                    )
                )
            }

            memoryPreviewResult = MemoryPreviewDemoResult(
                threadID: previewThreadID,
                threadTitle: previewThreadTitle,
                requestText: DemoMemoryExamples.previewRequestText,
                result: result,
                renderedPrompt: DefaultMemoryPromptRenderer().render(
                    result: result,
                    budget: DemoMemoryExamples.previewBudget
                )
            )
        } catch {
            reportError(error)
        }
    }
}
