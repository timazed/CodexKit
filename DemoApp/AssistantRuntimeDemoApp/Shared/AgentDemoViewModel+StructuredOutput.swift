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

    func runStreamedStructuredOutputDemo() async {
        guard session != nil else {
            lastError = "Sign in before running the streamed structured output demo."
            return
        }
        guard !isRunningStructuredStreamingDemo else {
            return
        }

        isRunningStructuredStreamingDemo = true
        lastError = nil
        structuredStreamingResult = nil
        structuredStreamingError = nil
        defer {
            isRunningStructuredStreamingDemo = false
        }

        do {
            let thread = try await runtime.createThread(
                title: "Structured Output: Streamed Delivery Update",
                personaStack: Self.supportPersona
            )
            let request = DemoStructuredOutputExamples.streamedStructuredRequest()
            if showResolvedInstructionsDebug {
                lastResolvedInstructions = try await runtime.resolvedInstructionsPreview(
                    for: thread.id,
                    request: request
                )
                lastResolvedInstructionsThreadTitle = thread.title ?? "Structured Output: Streamed Delivery Update"
            }

            let stream = try await runtime.streamMessage(
                request,
                in: thread.id,
                expecting: StreamedStructuredDeliveryUpdate.self
            )

            var visibleText = ""
            var partialSnapshots: [StreamedStructuredDeliveryUpdate] = []
            var committedPayload: StreamedStructuredDeliveryUpdate?

            for try await event in stream {
                switch event {
                case let .assistantMessageDelta(_, _, delta):
                    visibleText += delta

                case let .messageCommitted(message):
                    if message.role == .assistant {
                        visibleText = message.displayText
                    }

                case let .structuredOutputPartial(partial):
                    if partialSnapshots.last != partial {
                        partialSnapshots.append(partial)
                    }

                case let .structuredOutputCommitted(payload):
                    committedPayload = payload

                case let .turnFailed(error):
                    throw error

                default:
                    break
                }
            }

            let messages = await runtime.messages(for: thread.id)
            let persistedMetadata = messages.last(where: { $0.role == .assistant })?.structuredOutput

            guard let committedPayload else {
                throw AgentRuntimeError.structuredOutputMissing(
                    formatName: StreamedStructuredDeliveryUpdate.responseFormat.name
                )
            }

            structuredStreamingResult = StructuredStreamingDemoResult(
                threadID: thread.id,
                threadTitle: thread.title ?? "Structured Output: Streamed Delivery Update",
                prompt: DemoStructuredOutputExamples.streamedStructuredPrompt,
                visibleText: visibleText.trimmingCharacters(in: .whitespacesAndNewlines),
                partialSnapshots: partialSnapshots,
                committedPayload: committedPayload,
                persistedMetadata: persistedMetadata
            )
            threads = await runtime.threads()
            activeThreadID = thread.id
            setMessages(messages)
        } catch {
            structuredStreamingError = error.localizedDescription
            lastError = error.localizedDescription
        }
    }
}
