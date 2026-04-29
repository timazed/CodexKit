import CodexKit
import Foundation

@MainActor
extension AgentDemoViewModel {
    func restore() async {
        developerLog(
            "Restore started. store=\(resolvedStateURL.path) legacyJSONPresent=\(FileManager.default.fileExists(atPath: legacyStateURL.path))"
        )
        do {
            _ = try await runtime.restore()
            await registerDemoTool()
            await registerDemoSkills()
            await refreshSnapshot()
            developerLog(
                "Restore finished. sessionPresent=\(session != nil) threadCount=\(threads.count)"
            )
        } catch {
            reportError(error)
        }
    }

    func signIn(using authenticationMethod: DemoAuthenticationMethod) async {
        guard !isAuthenticating else {
            return
        }

        isAuthenticating = true
        lastError = nil
        currentAuthenticationMethod = authenticationMethod
        developerLog("Sign-in started. method=\(authenticationMethod.rawValue)")
        runtime = AgentDemoRuntimeFactory.makeRuntime(
            authenticationMethod: authenticationMethod,
            model: model,
            enableWebSearch: enableWebSearch,
            reasoningEffort: reasoningEffort,
            stateURL: stateURL,
            keychainAccount: keychainAccount,
            approvalInbox: approvalInbox,
            deviceCodePromptCoordinator: deviceCodePromptCoordinator
        )
        configureRuntimeObservationBindings()

        defer {
            isAuthenticating = false
        }

        do {
            _ = try await runtime.restore()
            await registerDemoTool()
            await registerDemoSkills()
            session = try await runtime.signIn()
            await refreshSnapshot()
            if healthCoachInitialized {
                await refreshHealthCoachProgress()
            }
            developerLog(
                "Sign-in finished. account=\(session?.account.email ?? "<unknown>") threadCount=\(threads.count)"
            )
        } catch {
            await deviceCodePromptCoordinator.clear()
            await refreshSnapshot()
            reportError(error)
        }
    }

    func updateReasoningEffort(_ reasoningEffort: ReasoningEffort) async {
        guard canReconfigureRuntime else {
            lastError = "Wait for the current turn to finish before switching thinking level."
            return
        }

        if let activeThreadID {
            let current = activeThread?.configuration ?? defaultThreadConfiguration
            let shouldUpdateDefault = self.reasoningEffort != reasoningEffort
            let shouldUpdateThread = current.reasoningEffort != reasoningEffort
            guard shouldUpdateDefault || shouldUpdateThread else {
                return
            }
            do {
                let updated = AgentThreadConfiguration(
                    model: current.model,
                    reasoningEffort: reasoningEffort
                )
                try await runtime.updateThreadConfiguration(updated, for: activeThreadID)
                self.reasoningEffort = reasoningEffort
                threads = await runtime.threads()
                observedThread = threads.first { $0.id == activeThreadID }
                developerLog(
                    "Updated thread configuration. threadID=\(activeThreadID) model=\(updated.model) reasoningEffort=\(updated.reasoningEffort.rawValue)"
                )
            } catch {
                reportError(error)
            }
        } else {
            guard self.reasoningEffort != reasoningEffort else {
                return
            }
            self.reasoningEffort = reasoningEffort
            developerLog(
                "Updated default thread configuration. model=\(model) reasoningEffort=\(reasoningEffort.rawValue)"
            )
        }
    }

    func createThread() async {
        await createThreadInternal(
            title: nil,
            personaStack: nil
        )
    }

    func createSupportPersonaThread() async {
        await createThreadInternal(
            title: "Support Persona Demo",
            personaStack: catalog.supportPersona
        )
    }

    func setPlannerPersonaOnActiveThread() async {
        guard let activeThreadID else {
            lastError = "Create or select a thread before swapping personas."
            return
        }

        do {
            try await runtime.setPersonaStack(
                catalog.plannerPersona,
                for: activeThreadID
            )
            threads = await runtime.threads()
        } catch {
            reportError(error)
        }
    }

    func sendReviewerOverrideExample() async {
        if activeThreadID == nil {
            await createSupportPersonaThread()
        }

        await sendMessageInternal(
            "Review this conversation setup and tell me the biggest risks first.",
            personaOverride: catalog.reviewerOverridePersona
        )
    }

    func createHealthCoachSkillThread() async {
        await createThreadInternal(
            title: "Skill Demo: Health Coach",
            personaStack: nil,
            skillIDs: [catalog.healthCoachSkill.id]
        )
    }

    func createTravelPlannerSkillThread() async {
        await createThreadInternal(
            title: "Skill Demo: Travel Planner",
            personaStack: nil,
            skillIDs: [catalog.travelPlannerSkill.id]
        )
    }

    func activateThread(id: String) async {
        activeThreadID = id
        bindActiveThreadObservation(for: id)
        setMessages(await runtime.messages(for: id))
        streamingText = ""
        await refreshThreadContextState(for: id)
    }

    func signOut() async {
        do {
            try await runtime.signOut()
            await deviceCodePromptCoordinator.clear()
            session = nil
            threads = []
            messages = []
            streamingText = ""
            composerText = ""
            pendingComposerImages = []
            lastResolvedInstructions = nil
            lastResolvedInstructionsThreadTitle = nil
            isRunningSkillPolicyProbe = false
            skillPolicyProbeResult = nil
            isRunningStructuredOutputDemo = false
            structuredShippingReplyResult = nil
            structuredImportedSummaryResult = nil
            isRunningMemoryDemo = false
            automaticMemoryResult = nil
            automaticPolicyMemoryResult = nil
            guidedMemoryResult = nil
            rawMemoryResult = nil
            memoryPreviewResult = nil
            activeThreadID = nil
            healthCoachThreadID = nil
            activeThreadObservationCancellables.removeAll()
            resetObservedThreadState()
            healthCoachFeedback = "Set a step goal, then start moving."
            healthLastUpdatedAt = nil
            healthKitAuthorized = false
            notificationAuthorized = false
            healthCoachInitialized = false
            cachedAICoachFeedbackKey = nil
            cachedAICoachFeedbackGeneratedAt = nil
            cachedAIReminderBody = nil
            cachedAIReminderKey = nil
            cachedAIReminderGeneratedAt = nil
            lastError = nil
        } catch {
            reportError(error)
        }
    }

    func refreshSnapshot() async {
        session = await runtime.currentSession()
        guard session != nil else {
            clearConversationSnapshot()
            developerLog("Snapshot refreshed with no active session.")
            return
        }

        threads = await runtime.threads()
        developerLog(
            "Snapshot refreshed. session=\(session?.account.email ?? "<unknown>") threadCount=\(threads.count)"
        )

        let selectedThreadID = activeThreadID
        if let selectedThreadID,
           threads.contains(where: { $0.id == selectedThreadID }) {
            bindActiveThreadObservation(for: selectedThreadID)
            setMessages(await runtime.messages(for: selectedThreadID))
            await refreshThreadContextState(for: selectedThreadID)
            return
        }

        if let firstThread = threads.first {
            activeThreadID = firstThread.id
            bindActiveThreadObservation(for: firstThread.id)
            setMessages(await runtime.messages(for: firstThread.id))
            await refreshThreadContextState(for: firstThread.id)
        } else {
            activeThreadID = nil
            messages = []
            resetObservedThreadState()
        }
    }

    func clearConversationSnapshot() {
        threads = []
        messages = []
        streamingText = ""
        pendingComposerImages = []
        lastResolvedInstructions = nil
        lastResolvedInstructionsThreadTitle = nil
        isRunningSkillPolicyProbe = false
        skillPolicyProbeResult = nil
        activeThreadID = nil
        activeThreadObservationCancellables.removeAll()
        resetObservedThreadState()
    }

    func refreshThreadContextState(for threadID: String? = nil) async {
        guard let resolvedThreadID = threadID ?? activeThreadID else {
            resetObservedThreadState()
            return
        }

        do {
            activeThreadContextState = try await runtime.fetchThreadContextState(id: resolvedThreadID)
            observedThreadContextState = activeThreadContextState
            activeThreadContextUsage = try await runtime.fetchThreadContextUsage(id: resolvedThreadID)
            observedThreadContextUsage = activeThreadContextUsage
        } catch {
            activeThreadContextState = nil
            observedThreadContextState = nil
            activeThreadContextUsage = nil
            observedThreadContextUsage = nil
            developerErrorLog("Failed to fetch thread context state. threadID=\(resolvedThreadID) error=\(error.localizedDescription)")
        }
    }

    func updateActiveThreadTitle(_ title: String) async {
        guard let activeThreadID else {
            lastError = "Select a thread before renaming it."
            return
        }

        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            try await runtime.setTitle(
                normalizedTitle.isEmpty ? nil : normalizedTitle,
                for: activeThreadID
            )
            developerLog(
                "Updated thread title. threadID=\(activeThreadID) title=\(normalizedTitle.isEmpty ? "<untitled>" : normalizedTitle)"
            )
        } catch {
            reportError(error)
        }
    }

    func compactActiveThreadContext() async {
        guard let activeThreadID else {
            lastError = "Select a thread before compacting its prompt context."
            return
        }
        guard !isCompactingThreadContext else {
            return
        }

        isCompactingThreadContext = true
        defer {
            isCompactingThreadContext = false
        }

        do {
            developerLog("Manual context compaction started. threadID=\(activeThreadID)")
            activeThreadContextState = try await runtime.compactThreadContext(id: activeThreadID)
            activeThreadContextUsage = try await runtime.fetchThreadContextUsage(id: activeThreadID)
            threads = await runtime.threads()
            setMessages(await runtime.messages(for: activeThreadID))
            developerLog(
                "Manual context compaction finished. threadID=\(activeThreadID) generation=\(activeThreadContextState?.generation ?? 0) effectiveTokens=\(activeThreadContextUsage?.effectiveEstimatedTokenCount ?? 0)"
            )
        } catch {
            reportError(error)
        }
    }
}
