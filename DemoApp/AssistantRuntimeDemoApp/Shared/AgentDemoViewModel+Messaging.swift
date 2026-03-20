import CodexKit
import Foundation

@MainActor
extension AgentDemoViewModel {
    func createThreadInternal(
        title: String?,
        personaStack: AgentPersonaStack?
    ) async {
        do {
            let thread = try await runtime.createThread(
                title: title,
                personaStack: personaStack
            )
            threads = await runtime.threads()
            activeThreadID = thread.id
            messages = await runtime.messages(for: thread.id)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func sendMessageInternal(
        _ text: String,
        images: [AgentImageAttachment] = [],
        personaOverride: AgentPersonaStack? = nil
    ) async {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedText.isEmpty || !images.isEmpty else {
            return
        }

        if activeThreadID == nil {
            await createThread()
        }

        guard let activeThreadID else {
            lastError = "No active thread is available."
            return
        }

        streamingText = ""

        do {
            let stream = try await runtime.sendMessage(
                UserMessageRequest(
                    text: trimmedText,
                    images: images,
                    personaOverride: personaOverride
                ),
                in: activeThreadID
            )
            messages = await runtime.messages(for: activeThreadID)

            for try await event in stream {
                switch event {
                case let .threadStarted(thread):
                    threads = [thread] + threads.filter { $0.id != thread.id }

                case let .threadStatusChanged(threadID, status):
                    threads = threads.map { thread in
                        guard thread.id == threadID else {
                            return thread
                        }

                        var updated = thread
                        updated.status = status
                        updated.updatedAt = Date()
                        return updated
                    }

                case .turnStarted:
                    break

                case let .assistantMessageDelta(_, _, delta):
                    streamingText.append(delta)

                case let .messageCommitted(message):
                    messages.append(message)
                    if message.role == .assistant {
                        streamingText = ""
                    }

                case .approvalRequested:
                    break

                case .approvalResolved:
                    break

                case let .toolCallStarted(invocation):
                    Self.logger.info(
                        "Tool call requested: \(invocation.toolName, privacy: .public) with arguments: \(String(describing: invocation.arguments), privacy: .public)"
                    )

                case let .toolCallFinished(result):
                    Self.logger.info(
                        "Tool call finished: \(result.toolName, privacy: .public) success=\(result.success, privacy: .public) output=\(result.primaryText ?? "<no text result>", privacy: .public)"
                    )

                case .turnCompleted:
                    messages = await runtime.messages(for: activeThreadID)
                    threads = await runtime.threads()

                case let .turnFailed(error):
                    lastError = error.message
                }
            }
        } catch {
            lastError = error.localizedDescription
        }
    }
}
