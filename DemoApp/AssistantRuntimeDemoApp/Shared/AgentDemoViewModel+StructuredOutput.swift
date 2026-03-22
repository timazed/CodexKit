import CodexKit
import Foundation

@MainActor
extension AgentDemoViewModel {
    func runStructuredShippingReplyDemo() async {
        guard session != nil else {
            lastError = "Sign in before running the structured output demo."
            return
        }
        guard !isRunningStructuredOutputDemo else {
            return
        }

        isRunningStructuredOutputDemo = true
        lastError = nil
        defer {
            isRunningStructuredOutputDemo = false
        }

        do {
            let thread = try await runtime.createThread(
                title: "Structured Output: Shipping Draft",
                personaStack: Self.supportPersona
            )
            let request = DemoStructuredOutputExamples.shippingReplyRequest()
            if showResolvedInstructionsDebug {
                lastResolvedInstructions = try await runtime.resolvedInstructionsPreview(
                    for: thread.id,
                    request: request
                )
                lastResolvedInstructionsThreadTitle = thread.title ?? "Structured Output: Shipping Draft"
            }

            let draft = try await runtime.sendMessage(
                request,
                in: thread.id,
                expecting: StructuredShippingReplyDraft.self
            )

            structuredShippingReplyResult = StructuredOutputDemoDraftResult(
                threadID: thread.id,
                threadTitle: thread.title ?? "Structured Output: Shipping Draft",
                customerMessage: DemoStructuredOutputExamples.shippingCustomerMessage,
                draft: draft
            )
            threads = await runtime.threads()
            activeThreadID = thread.id
            setMessages(await runtime.messages(for: thread.id))
        } catch {
            lastError = error.localizedDescription
        }
    }

    func runStructuredImportedSummaryDemo() async {
        guard session != nil else {
            lastError = "Sign in before running the imported content demo."
            return
        }
        guard !isRunningStructuredOutputDemo else {
            return
        }

        isRunningStructuredOutputDemo = true
        lastError = nil
        defer {
            isRunningStructuredOutputDemo = false
        }

        do {
            let thread = try await runtime.createThread(
                title: "Structured Output: Imported Summary"
            )
            let request = DemoStructuredOutputExamples.importedSummaryRequest()
            if showResolvedInstructionsDebug {
                lastResolvedInstructions = try await runtime.resolvedInstructionsPreview(
                    for: thread.id,
                    request: request
                )
                lastResolvedInstructionsThreadTitle = thread.title ?? "Structured Output: Imported Summary"
            }

            let summary = try await runtime.sendMessage(
                request,
                in: thread.id,
                expecting: StructuredImportedContentSummary.self
            )

            structuredImportedSummaryResult = StructuredOutputDemoImportResult(
                threadID: thread.id,
                threadTitle: thread.title ?? "Structured Output: Imported Summary",
                sourceURL: DemoStructuredOutputExamples.importedArticleURL,
                summary: summary
            )
            threads = await runtime.threads()
            activeThreadID = thread.id
            setMessages(await runtime.messages(for: thread.id))
        } catch {
            lastError = error.localizedDescription
        }
    }
}
