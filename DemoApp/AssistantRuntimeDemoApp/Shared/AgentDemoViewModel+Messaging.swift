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
                configuration: defaultThreadConfiguration,
                personaStack: personaStack,
                skillIDs: skillIDs
            )
            threads = await runtime.threads()
            activeThreadID = thread.id
            bindActiveThreadObservation(for: thread.id)
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

        let request = Request(
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
                title: "Skill Policy Probe: Normal",
                configuration: defaultThreadConfiguration
            )
            let skillThread = try await runtime.createThread(
                title: "Skill Policy Probe: Health Coach",
                configuration: defaultThreadConfiguration,
                skillIDs: [catalog.healthCoachSkill.id]
            )
            threads = await runtime.threads()

            let normalDiagnostics = try await sendRequest(
                Request(text: probePrompt),
                in: normalThread.id,
                captureResolvedInstructions: true,
                renderInActiveTranscript: false
            )

            let skillDiagnostics = try await sendRequest(
                Request(text: probePrompt),
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

    func runEphemeralTurnDemo() async {
        guard session != nil else {
            lastError = "Sign in before sending an ephemeral turn."
            return
        }
        guard !isRunningEphemeralTurnDemo else {
            return
        }

        if activeThreadID == nil {
            await createThread()
        }

        guard let activeThreadID else {
            lastError = "No active thread is available."
            return
        }

        isRunningEphemeralTurnDemo = true
        lastError = nil
        ephemeralTurnResult = nil
        defer {
            isRunningEphemeralTurnDemo = false
        }

        let prompt = """
        Give a one-sentence status note for a transient notification preview. Do not rely on previous chat history.
        """
        let messageCountBefore = await runtime.messages(for: activeThreadID).count
        let request = Request(
            text: prompt,
            executionMode: .ephemeral
        )

        do {
            developerLog(
                "Sending ephemeral turn. threadID=\(activeThreadID) textLength=\(prompt.count) messageCountBefore=\(messageCountBefore)"
            )
            let diagnostics = try await sendRequest(
                request,
                in: activeThreadID,
                captureResolvedInstructions: showResolvedInstructionsDebug,
                renderInActiveTranscript: false
            )
            let messageCountAfter = await runtime.messages(for: activeThreadID).count
            let threadTitle = threads.first(where: { $0.id == activeThreadID })?.title ?? "Untitled Thread"
            ephemeralTurnResult = EphemeralTurnDemoResult(
                threadID: activeThreadID,
                threadTitle: threadTitle,
                prompt: prompt,
                assistantReply: diagnostics.assistantReply ?? "No assistant text was committed.",
                messageCountBefore: messageCountBefore,
                messageCountAfter: messageCountAfter
            )
            setMessages(await runtime.messages(for: activeThreadID))
            developerLog(
                "Ephemeral turn completed. threadID=\(activeThreadID) messageCountAfter=\(messageCountAfter)"
            )
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
        _ request: Request,
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
        var bufferedStreamingText = ""
        var lastStreamingFlushAt = Date.distantPast

        developerLog(
            "Starting streamed turn. threadID=\(threadID) textLength=\(request.text.count) imageCount=\(request.images.count) ephemeral=\(request.isEphemeral)"
        )

        let stream = try await runtime.stream(
            request,
            in: threadID
        )
        if renderInActiveTranscript {
            setMessages(await runtime.messages(for: threadID))
        }

        func flushStreamingText(force: Bool = false) {
            guard renderInActiveTranscript else {
                return
            }
            guard !bufferedStreamingText.isEmpty else {
                return
            }

            let now = Date()
            guard force || now.timeIntervalSince(lastStreamingFlushAt) >= 0.05 else {
                return
            }

            streamingText.append(bufferedStreamingText)
            bufferedStreamingText.removeAll(keepingCapacity: true)
            lastStreamingFlushAt = now
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
                    bufferedStreamingText.append(delta)
                    flushStreamingText()
                }

            case let .messageCommitted(message):
                flushStreamingText(force: true)
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
                developerLog(
                    "Tool call requested. threadID=\(threadID) tool=\(invocation.toolName) arguments=\(String(describing: invocation.arguments))"
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
                developerLog(
                    "Tool call finished. threadID=\(threadID) tool=\(result.toolName) success=\(result.success) output=\(result.primaryText ?? result.errorMessage ?? "<no text result>")"
                )

            case .turnCompleted:
                flushStreamingText(force: true)
                if renderInActiveTranscript {
                    setMessages(await runtime.messages(for: threadID))
                }
                threads = await runtime.threads()
                developerLog("Turn completed. threadID=\(threadID)")
                await refreshThreadContextState(for: threadID)

            case let .turnFailed(error):
                flushStreamingText(force: true)
                diagnostics.turnFailedCode = error.code
                developerErrorLog(
                    "Turn failed. threadID=\(threadID) code=\(error.code) message=\(error.message)"
                )
                await refreshThreadContextState(for: threadID)
                reportError(error.message)
            }
        }

        return diagnostics
    }
}
