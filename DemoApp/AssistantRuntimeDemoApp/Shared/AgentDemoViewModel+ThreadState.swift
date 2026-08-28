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
        defer {
            isAuthenticating = false
        }

        do {
            runtime = try AgentDemoRuntimeFactory.makeRuntime(
                authenticationMethod: authenticationMethod,
                model: model,
                enableWebSearch: enableWebSearch,
                enableImageGeneration: enableImageGeneration,
                reasoningEffort: reasoningEffort,
                persistenceAdapter: persistenceAdapter,
                stateURL: stateURL,
                keychainAccount: keychainAccount,
                approvalInbox: approvalInbox,
                deviceCodePromptCoordinator: deviceCodePromptCoordinator
            )
            configureRuntimeObservationBindings()
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

    func updatePersistenceAdapter(_ selectedAdapter: DemoPersistenceAdapter) async {
        guard selectedAdapter != persistenceAdapter else {
            return
        }
        guard canReconfigureRuntime else {
            lastError = "Wait for the current operation to finish before switching persistence adapters."
            return
        }

        isSwitchingPersistenceAdapter = true
        lastError = nil
        developerLog(
            "Persistence switch started. from=\(persistenceAdapter.rawValue) to=\(selectedAdapter.rawValue)"
        )
        defer {
            isSwitchingPersistenceAdapter = false
        }

        do {
            let replacementRuntime = try AgentDemoRuntimeFactory.makeRuntime(
                authenticationMethod: currentAuthenticationMethod,
                model: model,
                enableWebSearch: enableWebSearch,
                enableImageGeneration: enableImageGeneration,
                reasoningEffort: reasoningEffort,
                persistenceAdapter: selectedAdapter,
                stateURL: stateURL,
                keychainAccount: keychainAccount,
                approvalInbox: approvalInbox,
                deviceCodePromptCoordinator: deviceCodePromptCoordinator
            )
            _ = try await replacementRuntime.restore()
            runtime = replacementRuntime
            persistenceAdapter = selectedAdapter
            AgentDemoRuntimeFactory.persistPersistenceAdapter(selectedAdapter)
            clearThreadCatalog()
            activeThreadID = nil
            healthCoachThreadID = nil
            automaticMemoryResult = nil
            automaticPolicyMemoryResult = nil
            guidedMemoryResult = nil
            rawMemoryResult = nil
            memoryPreviewResult = nil
            configureRuntimeObservationBindings()
            await registerDemoTool()
            await registerDemoSkills()
            await refreshSnapshot()
            if healthCoachInitialized {
                await refreshHealthCoachProgress()
            }
            developerLog(
                "Persistence switch finished. adapter=\(persistenceAdapter.rawValue) store=\(resolvedStateURL.path)"
            )
        } catch {
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
                threads = await runtime.activeThreads()
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

    func updateModel(_ selectedModel: CodexModel) async {
        guard canReconfigureRuntime else {
            lastError = "Wait for the current turn to finish before switching models."
            return
        }

        let current = activeThread?.configuration ?? defaultThreadConfiguration
        let modelInfo = selectedModel.info
        let resolvedReasoningEffort = modelInfo?.supports(current.reasoningEffort) != false
            ? current.reasoningEffort
            : modelInfo?.defaultReasoningEffort ?? current.reasoningEffort

        if let activeThreadID {
            guard current.model != selectedModel.rawValue ||
                current.reasoningEffort != resolvedReasoningEffort ||
                model != selectedModel.rawValue else {
                return
            }
            do {
                let updated = AgentThreadConfiguration(
                    model: selectedModel.rawValue,
                    reasoningEffort: resolvedReasoningEffort
                )
                try await runtime.updateThreadConfiguration(updated, for: activeThreadID)
                model = selectedModel.rawValue
                reasoningEffort = resolvedReasoningEffort
                threads = await runtime.activeThreads()
                observedThread = threads.first { $0.id == activeThreadID }
                await refreshThreadContextState(for: activeThreadID)
                developerLog(
                    "Updated thread model. threadID=\(activeThreadID) model=\(updated.model) reasoningEffort=\(updated.reasoningEffort.rawValue)"
                )
            } catch {
                reportError(error)
            }
        } else {
            guard model != selectedModel.rawValue || reasoningEffort != resolvedReasoningEffort else {
                return
            }
            model = selectedModel.rawValue
            reasoningEffort = resolvedReasoningEffort
            developerLog(
                "Updated default thread model. model=\(model) reasoningEffort=\(reasoningEffort.rawValue)"
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
            threads = await runtime.activeThreads()
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

    func runImageGenerationDemo() async {
        guard enableImageGeneration else {
            lastError = "Image generation is not enabled for this demo runtime."
            return
        }

        await createThreadInternal(
            title: "Image Generation Demo",
            personaStack: nil
        )

        await sendMessageInternal(
            """
            Generate a clean square app-icon style image of a small assistant workstation: a laptop, a speech bubble, and a tiny paintbrush. Use a crisp modern style and no text.
            """
        )
    }

    func activateThread(id: String) async {
        do {
            _ = try await runtime.resumeThread(id: id)
            threads = await runtime.activeThreads()
            activeThreadID = id
            bindActiveThreadObservation(for: id)
            setMessages(await runtime.messages(for: id))
            streamingText = ""
            await refreshThreadContextState(for: id)
        } catch {
            reportError(error)
        }
    }

    func signOut() async {
        do {
            try await runtime.signOut()
            await deviceCodePromptCoordinator.clear()
            await refreshThreadCatalog()
            session = nil
            activeRuntimeThreads = []
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
            activeThreadObservationBindingTask?.cancel()
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
        await refreshThreadCatalog()
        guard session != nil else {
            clearConversationSnapshot()
            developerLog(
                "Snapshot refreshed with no active session. persistedThreadCount=\(persistedThreads.count)"
            )
            return
        }

        developerLog(
            "Snapshot refreshed. session=\(session?.account.email ?? "<unknown>") threadCount=\(threads.count)"
        )

        let selectedThreadID = activeThreadID
        if let selectedThreadID,
           activeRuntimeThreads.contains(where: { $0.id == selectedThreadID }) {
            bindActiveThreadObservation(for: selectedThreadID)
            setMessages(await runtime.messages(for: selectedThreadID))
            await refreshThreadContextState(for: selectedThreadID)
            return
        }

        if let firstThread = activeRuntimeThreads.first {
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
        activeRuntimeThreads = []
        messages = []
        streamingText = ""
        pendingComposerImages = []
        lastResolvedInstructions = nil
        lastResolvedInstructionsThreadTitle = nil
        isRunningSkillPolicyProbe = false
        skillPolicyProbeResult = nil
        activeThreadID = nil
        activeThreadObservationBindingTask?.cancel()
        activeThreadObservationCancellables.removeAll()
        resetObservedThreadState()
    }

    func refreshThreadCatalog() async {
        do {
            persistedThreads = try await runtime.persistedThreads()
        } catch {
            persistedThreads = await runtime.activeThreads()
            developerErrorLog(
                "Failed to query persisted thread metadata. error=\(error.localizedDescription)"
            )
        }
        activeRuntimeThreads = await runtime.activeThreads()
    }

    func clearThreadCatalog() {
        persistedThreads = []
        activeRuntimeThreads = []
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
            threads = await runtime.activeThreads()
            setMessages(await runtime.messages(for: activeThreadID))
            developerLog(
                "Manual context compaction finished. threadID=\(activeThreadID) generation=\(activeThreadContextState?.generation ?? 0) effectiveTokens=\(activeThreadContextUsage?.effectiveEstimatedTokenCount ?? 0)"
            )
        } catch {
            reportError(error)
        }
    }
}
