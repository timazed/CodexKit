import CodexKit
import Foundation

@MainActor
extension AgentDemoViewModel {
    private struct SendDiagnostics {
        var sawToolCall = false
        var sawSuccessfulToolResult = false
        var sawFailedToolResult = false
        var firstFailureMessage: String?
        var turnFailedCode: String?
        var assistantReply: String?
    }

    func createThreadInternal(
        title: String?,
        personaStack: AgentPersonaStack?,
        skillIDs: [String] = []
    ) async {
        do {
            developerLog(
                "Creating thread. title=\(title ?? "<untitled>") skills=\(skillIDs.joined(separator: ",")) personaLayers=\(personaStack?.layers.count ?? 0)"
            )
            let thread = try await runtime.createThread(
                title: title,
                personaStack: personaStack,
                skillIDs: skillIDs
            )
            threads = await runtime.threads()
            activeThreadID = thread.id
            setMessages(await runtime.messages(for: thread.id))
            developerLog(
                "Created thread. id=\(thread.id) title=\(thread.title ?? "<untitled>") totalThreads=\(threads.count)"
            )
        } catch {
            reportError(error)
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

        let request = UserMessageRequest(
            text: trimmedText,
            images: images,
            personaOverride: personaOverride
        )

        do {
            developerLog(
                "Sending message. threadID=\(activeThreadID) textLength=\(trimmedText.count) images=\(images.count) personaOverrideLayers=\(personaOverride?.layers.count ?? 0)"
            )
            _ = try await sendRequest(
                request,
                in: activeThreadID,
                captureResolvedInstructions: showResolvedInstructionsDebug,
                renderInActiveTranscript: true
            )
        } catch {
            reportError(error)
        }
    }

    func runSkillPolicyProbe() async {
        guard session != nil else {
            lastError = "Sign in before running the skill policy probe."
            return
        }
        guard !isRunningSkillPolicyProbe else {
            return
        }

        isRunningSkillPolicyProbe = true
        lastError = nil
        skillPolicyProbeResult = nil
        showResolvedInstructionsDebug = true
        defer {
            isRunningSkillPolicyProbe = false
        }

        let probePrompt = """
        Give me a practical plan for the rest of today.
        """

        do {
            let normalThread = try await runtime.createThread(
                title: "Skill Policy Probe: Normal"
            )
            let skillThread = try await runtime.createThread(
                title: "Skill Policy Probe: Health Coach",
                skillIDs: [Self.healthCoachSkill.id]
            )
            threads = await runtime.threads()

            let normalDiagnostics = try await sendRequest(
                UserMessageRequest(text: probePrompt),
                in: normalThread.id,
                captureResolvedInstructions: true,
                renderInActiveTranscript: false
            )

            let skillDiagnostics = try await sendRequest(
                UserMessageRequest(text: probePrompt),
                in: skillThread.id,
                captureResolvedInstructions: true,
                renderInActiveTranscript: false
            )

            threads = await runtime.threads()
            streamingText = ""
            activeThreadID = skillThread.id
            setMessages(await runtime.messages(for: skillThread.id))

            let normalSummary = diagnosticsSummary(
                normalDiagnostics,
                fallback: "No tool call was emitted by the model in the normal thread."
            )
            let skillSummary = diagnosticsSummary(
                skillDiagnostics,
                fallback: "No tool call was emitted by the model in the skill thread."
            )

            skillPolicyProbeResult = SkillPolicyProbeResult(
                prompt: probePrompt,
                normalThreadID: normalThread.id,
                normalThreadTitle: normalThread.title ?? "Skill Policy Probe: Normal",
                skillThreadID: skillThread.id,
                skillThreadTitle: skillThread.title ?? "Skill Policy Probe: Health Coach",
                normalSummary: normalSummary,
                skillSummary: skillSummary,
                normalAssistantReply: normalDiagnostics.assistantReply,
                skillAssistantReply: skillDiagnostics.assistantReply,
                skillToolSucceeded: skillDiagnostics.sawSuccessfulToolResult
            )

            if skillPolicyProbeResult?.passed == false {
                lastError = "Probe completed, but result was inconclusive. Review the two thread summaries."
            }
        } catch {
            reportError(error)
        }
    }

    private func diagnosticsSummary(
        _ diagnostics: SendDiagnostics,
        fallback: String
    ) -> String {
        if diagnostics.sawSuccessfulToolResult {
            return "Tool executed successfully."
        }
        if let failureMessage = diagnostics.firstFailureMessage,
           !failureMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Tool blocked: \(failureMessage)"
        }
        if let turnFailedCode = diagnostics.turnFailedCode {
            return "Turn failed: \(turnFailedCode)"
        }
        if diagnostics.sawToolCall {
            return "Tool call was requested, but no final tool result was captured."
        }
        return fallback
    }

    private func sendRequest(
        _ request: UserMessageRequest,
        in threadID: String,
        captureResolvedInstructions: Bool,
        renderInActiveTranscript: Bool
    ) async throws -> SendDiagnostics {
        if captureResolvedInstructions {
            do {
                lastResolvedInstructions = try await runtime.resolvedInstructionsPreview(
                    for: threadID,
                    request: request
                )
                let threadTitle = threads.first(where: { $0.id == threadID })?.title
                lastResolvedInstructionsThreadTitle = threadTitle ?? "Untitled Thread"
                developerLog(
                    "Captured resolved instructions. threadID=\(threadID) title=\(lastResolvedInstructionsThreadTitle ?? "Untitled Thread")"
                )
            } catch {
                lastResolvedInstructions = nil
                lastResolvedInstructionsThreadTitle = nil
                throw error
            }
        } else {
            lastResolvedInstructions = nil
            lastResolvedInstructionsThreadTitle = nil
        }

        var diagnostics = SendDiagnostics()
        if renderInActiveTranscript {
            streamingText = ""
        }

        developerLog(
            "Starting streamed turn. threadID=\(threadID) textLength=\(request.text?.count ?? 0) imageCount=\(request.images.count)"
        )

        let stream = try await runtime.streamMessage(
            request,
            in: threadID
        )
        if renderInActiveTranscript {
            setMessages(await runtime.messages(for: threadID))
        }

        for try await event in stream {
            switch event {
            case let .threadStarted(thread):
                threads = [thread] + threads.filter { $0.id != thread.id }
                developerLog(
                    "Thread started event. id=\(thread.id) title=\(thread.title ?? "<untitled>") status=\(thread.status.rawValue)"
                )

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
                developerLog("Thread status changed. threadID=\(threadID) status=\(status.rawValue)")

            case .turnStarted:
                developerLog("Turn started. threadID=\(threadID)")

            case let .assistantMessageDelta(_, _, delta):
                if renderInActiveTranscript {
                    streamingText.append(delta)
                }

            case let .messageCommitted(message):
                if message.role == .assistant {
                    let reply = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !reply.isEmpty {
                        diagnostics.assistantReply = reply
                    }
                }
                if renderInActiveTranscript {
                    upsertMessage(message)
                    if message.role == .assistant {
                        streamingText = ""
                    }
                }
                developerLog(
                    "Message committed. threadID=\(threadID) role=\(message.role.rawValue) textLength=\(message.text.count)"
                )

            case .approvalRequested:
                developerLog("Approval requested. threadID=\(threadID)")

            case .approvalResolved:
                developerLog("Approval resolved. threadID=\(threadID)")

            case let .toolCallStarted(invocation):
                diagnostics.sawToolCall = true
                Self.logger.info(
                    "Tool call requested: \(invocation.toolName, privacy: .public) with arguments: \(String(describing: invocation.arguments), privacy: .public)"
                )

            case let .toolCallFinished(result):
                diagnostics.sawToolCall = true
                if result.success {
                    diagnostics.sawSuccessfulToolResult = true
                } else {
                    diagnostics.sawFailedToolResult = true
                    if diagnostics.firstFailureMessage == nil {
                        diagnostics.firstFailureMessage = result.primaryText ?? result.errorMessage
                    }
                }
                Self.logger.info(
                    "Tool call finished: \(result.toolName, privacy: .public) success=\(result.success, privacy: .public) output=\(result.primaryText ?? "<no text result>", privacy: .public)"
                )

            case .turnCompleted:
                if renderInActiveTranscript {
                    setMessages(await runtime.messages(for: threadID))
                }
                threads = await runtime.threads()
                developerLog("Turn completed. threadID=\(threadID)")

            case let .turnFailed(error):
                diagnostics.turnFailedCode = error.code
                developerErrorLog(
                    "Turn failed. threadID=\(threadID) code=\(error.code) message=\(error.message)"
                )
                lastError = error.message
            }
        }

        return diagnostics
    }
}
