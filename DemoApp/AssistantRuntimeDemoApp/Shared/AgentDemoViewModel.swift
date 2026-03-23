import CodexKit
import CodexKitUI
import Foundation
import OSLog
import Observation
#if os(iOS)
import HealthKit
import UserNotifications
#endif

struct SkillPolicyProbeResult: Sendable {
    let prompt: String
    let normalThreadID: String
    let normalThreadTitle: String
    let skillThreadID: String
    let skillThreadTitle: String
    let normalSummary: String
    let skillSummary: String
    let normalAssistantReply: String?
    let skillAssistantReply: String?
    let skillToolSucceeded: Bool

    var passed: Bool {
        skillToolSucceeded
    }
}

struct StructuredOutputDemoDraftResult: Sendable {
    let threadID: String
    let threadTitle: String
    let customerMessage: String
    let draft: StructuredShippingReplyDraft
}

struct StructuredOutputDemoImportResult: Sendable {
    let threadID: String
    let threadTitle: String
    let sourceURL: URL
    let summary: StructuredImportedContentSummary
}

struct StructuredStreamingDemoResult: Sendable {
    let threadID: String
    let threadTitle: String
    let prompt: String
    let visibleText: String
    let partialSnapshots: [StreamedStructuredDeliveryUpdate]
    let committedPayload: StreamedStructuredDeliveryUpdate
    let persistedMetadata: AgentStructuredOutputMetadata?
}

struct GuidedMemoryDemoResult: Sendable {
    let record: MemoryRecord
    let diagnostics: MemoryStoreDiagnostics
}

struct RawMemoryDemoResult: Sendable {
    let record: MemoryRecord
    let diagnostics: MemoryStoreDiagnostics
}

struct MemoryPreviewDemoResult: Sendable {
    let threadID: String?
    let threadTitle: String?
    let requestText: String
    let result: MemoryQueryResult
    let renderedPrompt: String
}

struct AutomaticMemoryDemoResult: Sendable {
    let threadID: String
    let threadTitle: String
    let capture: MemoryCaptureResult
}

struct AutomaticPolicyMemoryDemoResult: Sendable {
    let threadID: String
    let threadTitle: String
    let prompt: String
    let records: [MemoryRecord]
}

@MainActor
@Observable
final class AgentDemoViewModel: @unchecked Sendable {
    nonisolated static let developerLoggingDefaultsKey = "AssistantRuntimeDemoApp.developerLoggingEnabled"
    nonisolated static let logger = Logger(
        subsystem: "ai.assistantruntime.demoapp",
        category: "DemoTool"
    )
    nonisolated static let supportPersona = AgentPersonaStack(layers: [
        .init(
            name: "domain",
            instructions: "You are an expert customer support agent for a shipping app."
        ),
        .init(
            name: "style",
            instructions: "Be concise, calm, and action-oriented."
        ),
    ])
    nonisolated static let plannerPersona = AgentPersonaStack(layers: [
        .init(
            name: "planner",
            instructions: "Act as a careful technical planner. Focus on tradeoffs and implementation sequencing."
        ),
    ])
    nonisolated static let reviewerOverridePersona = AgentPersonaStack(layers: [
        .init(
            name: "reviewer",
            instructions: "For this reply only, act as a strict reviewer and call out risks first."
        ),
    ])
    nonisolated static let healthCoachToolName = "health_coach_fetch_progress"
    nonisolated static let travelPlannerToolName = "travel_planner_build_day_plan"
    nonisolated static let healthCoachSkill = AgentSkill(
        id: "health_coach",
        name: "Health Coach",
        instructions: "You are a health coach focused on daily step goals and execution. For every user turn, call the \(healthCoachToolName) tool exactly once before your final reply, then provide one practical walking plan and one accountability line.",
        executionPolicy: .init(
            allowedToolNames: [healthCoachToolName],
            requiredToolNames: [healthCoachToolName],
            maxToolCalls: 1
        )
    )
    nonisolated static let travelPlannerSkill = AgentSkill(
        id: "travel_planner",
        name: "Travel Planner",
        instructions: "You are a travel planning assistant for mobile users. Provide concise day-by-day itineraries, practical logistics, and a compact packing checklist.",
        executionPolicy: .init(
            allowedToolNames: [travelPlannerToolName],
            maxToolCalls: 1
        )
    )

    var session: ChatGPTSession?
    var threads: [AgentThread] = []
    var messages: [AgentMessage] = []
    var streamingText = ""
    var lastError: String?
    var showResolvedInstructionsDebug = false
    var developerLoggingEnabled: Bool {
        didSet {
            UserDefaults.standard.set(
                developerLoggingEnabled,
                forKey: Self.developerLoggingDefaultsKey
            )
            developerLog(
                developerLoggingEnabled
                    ? "Developer logging enabled."
                    : "Developer logging disabled."
            )
        }
    }
    var lastResolvedInstructions: String?
    var lastResolvedInstructionsThreadTitle: String?
    var isRunningSkillPolicyProbe = false
    var skillPolicyProbeResult: SkillPolicyProbeResult?
    var isAuthenticating = false
    var pendingComposerImages: [AgentImageAttachment] = []
    var composerText = ""
    var isRunningStructuredOutputDemo = false
    var isRunningStructuredStreamingDemo = false
    var structuredShippingReplyResult: StructuredOutputDemoDraftResult?
    var structuredImportedSummaryResult: StructuredOutputDemoImportResult?
    var structuredStreamingResult: StructuredStreamingDemoResult?
    var structuredStreamingError: String?
    var isRunningMemoryDemo = false
    var automaticMemoryResult: AutomaticMemoryDemoResult?
    var automaticPolicyMemoryResult: AutomaticPolicyMemoryDemoResult?
    var guidedMemoryResult: GuidedMemoryDemoResult?
    var rawMemoryResult: RawMemoryDemoResult?
    var memoryPreviewResult: MemoryPreviewDemoResult?
    var healthKitAuthorized = false
    var notificationAuthorized = false
    var isRefreshingHealthCoach = false
    var isAskingHealthCoach = false
    var healthCoachInitialized = false
    var todayStepCount = 0
    var dailyStepGoal = 10_000
    var healthCoachToneMode: HealthCoachToneMode = .hardcorePersonal
    var healthCoachFeedback = "Set a step goal, then start moving."
    var healthLastUpdatedAt: Date?
    var cachedAICoachFeedbackKey: String?
    var cachedAICoachFeedbackGeneratedAt: Date?
    var cachedAIReminderBody: String?
    var cachedAIReminderKey: String?
    var cachedAIReminderGeneratedAt: Date?
    var reasoningEffort: ReasoningEffort
    var currentAuthenticationMethod: DemoAuthenticationMethod = .deviceCode

    let approvalInbox: ApprovalInbox
    let deviceCodePromptCoordinator: DeviceCodePromptCoordinator
    let model: String
    let enableWebSearch: Bool
    let stateURL: URL?
    let keychainAccount: String

    var runtime: AgentRuntime
    var activeThreadID: String?
    var healthCoachThreadID: String?

#if os(iOS)
    let healthStore = HKHealthStore()
    let notificationCenter = UNUserNotificationCenter.current()
#endif

    init(
        runtime: AgentRuntime,
        model: String,
        enableWebSearch: Bool,
        reasoningEffort: ReasoningEffort,
        stateURL: URL?,
        keychainAccount: String,
        approvalInbox: ApprovalInbox,
        deviceCodePromptCoordinator: DeviceCodePromptCoordinator = DeviceCodePromptCoordinator()
    ) {
        self.runtime = runtime
        self.model = model
        self.enableWebSearch = enableWebSearch
        self.reasoningEffort = reasoningEffort
        self.developerLoggingEnabled = UserDefaults.standard.bool(
            forKey: Self.developerLoggingDefaultsKey
        )
        self.stateURL = stateURL
        self.keychainAccount = keychainAccount
        self.approvalInbox = approvalInbox
        self.deviceCodePromptCoordinator = deviceCodePromptCoordinator
    }

    var activeThread: AgentThread? {
        guard let activeThreadID else {
            return nil
        }
        return threads.first { $0.id == activeThreadID }
    }

    var activeThreadPersonaSummary: String? {
        personaSummary(for: activeThread)
    }

    var resolvedStateURL: URL {
        stateURL ?? AgentDemoRuntimeFactory.defaultStateURL()
    }

    var legacyStateURL: URL {
        resolvedStateURL.deletingPathExtension().appendingPathExtension("json")
    }

    var healthProgressFraction: Double {
        guard dailyStepGoal > 0 else {
            return 0
        }
        return min(Double(todayStepCount) / Double(dailyStepGoal), 1)
    }

    var remainingStepCount: Int {
        max(dailyStepGoal - todayStepCount, 0)
    }

    var hasMetDailyGoal: Bool {
        dailyStepGoal > 0 && todayStepCount >= dailyStepGoal
    }

    var canReconfigureRuntime: Bool {
        !isAuthenticating && threads.allSatisfy { thread in
            switch thread.status {
            case .idle, .failed:
                true
            case .streaming, .waitingForApproval, .waitingForToolResult:
                false
            }
        }
    }

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
        guard self.reasoningEffort != reasoningEffort else {
            return
        }

        guard canReconfigureRuntime else {
            lastError = "Wait for the current turn to finish before switching thinking level."
            return
        }

        self.reasoningEffort = reasoningEffort
        developerLog("Reconfiguring runtime. reasoningEffort=\(reasoningEffort.rawValue)")
        let preservedActiveThreadID = activeThreadID
        let preservedHealthCoachThreadID = healthCoachThreadID

        runtime = AgentDemoRuntimeFactory.makeRuntime(
            authenticationMethod: currentAuthenticationMethod,
            model: model,
            enableWebSearch: enableWebSearch,
            reasoningEffort: reasoningEffort,
            stateURL: stateURL,
            keychainAccount: keychainAccount,
            approvalInbox: approvalInbox,
            deviceCodePromptCoordinator: deviceCodePromptCoordinator
        )

        do {
            _ = try await runtime.restore()
            await registerDemoTool()
            await refreshSnapshot()

            if let preservedActiveThreadID,
               threads.contains(where: { $0.id == preservedActiveThreadID }) {
                activeThreadID = preservedActiveThreadID
                messages = await runtime.messages(for: preservedActiveThreadID)
            }

            if let preservedHealthCoachThreadID,
               threads.contains(where: { $0.id == preservedHealthCoachThreadID }) {
                healthCoachThreadID = preservedHealthCoachThreadID
            }
            developerLog(
                "Runtime reconfigured. reasoningEffort=\(reasoningEffort.rawValue) threadCount=\(threads.count)"
            )
        } catch {
            reportError(error)
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
            personaStack: Self.supportPersona
        )
    }

    func setPlannerPersonaOnActiveThread() async {
        guard let activeThreadID else {
            lastError = "Create or select a thread before swapping personas."
            return
        }

        do {
            try await runtime.setPersonaStack(
                Self.plannerPersona,
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
            personaOverride: Self.reviewerOverridePersona
        )
    }

    func createHealthCoachSkillThread() async {
        await createThreadInternal(
            title: "Skill Demo: Health Coach",
            personaStack: nil,
            skillIDs: [Self.healthCoachSkill.id]
        )
    }

    func createTravelPlannerSkillThread() async {
        await createThreadInternal(
            title: "Skill Demo: Travel Planner",
            personaStack: nil,
            skillIDs: [Self.travelPlannerSkill.id]
        )
    }

    func personaSummary(for thread: AgentThread?) -> String? {
        guard let thread else {
            return nil
        }
        var sections: [String] = []
        if let layers = thread.personaStack?.layers, !layers.isEmpty {
            sections.append("persona: \(layers.map(\.name).joined(separator: ", "))")
        }
        if !thread.skillIDs.isEmpty {
            sections.append("skills: \(thread.skillIDs.joined(separator: ", "))")
        }
        guard !sections.isEmpty else { return nil }
        return sections.joined(separator: " | ")
    }

    func activateThread(id: String) async {
        activeThreadID = id
        setMessages(await runtime.messages(for: id))
        streamingText = ""
    }

    func sendComposerText() async {
        let outgoingText = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        let outgoingImages = pendingComposerImages

        guard !outgoingText.isEmpty || !outgoingImages.isEmpty else {
            return
        }

        composerText = ""
        pendingComposerImages = []
        await sendMessageInternal(
            outgoingText,
            images: outgoingImages
        )
    }

    func queueComposerImage(
        data: Data,
        mimeType: String
    ) {
        pendingComposerImages.append(
            AgentImageAttachment(
                mimeType: mimeType,
                data: data
            )
        )
    }

    func removePendingComposerImage(id: String) {
        pendingComposerImages.removeAll { $0.id == id }
    }

    func reportError(_ message: String) {
        developerErrorLog(message)
        lastError = message
    }

    func reportError(_ error: Error) {
        guard !Self.isCancellationError(error) else {
            developerLog("Ignoring CancellationError from async UI task.")
            return
        }
        developerErrorLog(error.localizedDescription)
        lastError = error.localizedDescription
    }

    func approvePendingRequest() {
        approvalInbox.approveCurrent()
    }

    func denyPendingRequest() {
        approvalInbox.denyCurrent()
    }

    func dismissError() {
        lastError = nil
    }

    nonisolated static func isCancellationError(_ error: Error) -> Bool {
        error is CancellationError
    }

    func developerLog(_ message: String) {
        guard developerLoggingEnabled else {
            return
        }
        Self.logger.notice("\(message, privacy: .public)")
        print("[CodexKit Demo] \(message)")
    }

    func developerErrorLog(_ message: String) {
        guard developerLoggingEnabled else {
            return
        }
        Self.logger.error("\(message, privacy: .public)")
        print("[CodexKit Demo][Error] \(message)")
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
            setMessages(await runtime.messages(for: selectedThreadID))
            return
        }

        if let firstThread = threads.first {
            activeThreadID = firstThread.id
            setMessages(await runtime.messages(for: firstThread.id))
        } else {
            activeThreadID = nil
            messages = []
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
    }

    func setMessages(_ incoming: [AgentMessage]) {
        messages = deduplicatedMessages(incoming)
    }

    func upsertMessage(_ message: AgentMessage) {
        if let existingIndex = messages.firstIndex(where: { $0.id == message.id }) {
            messages[existingIndex] = message
            return
        }
        messages.append(message)
    }

    private func deduplicatedMessages(_ incoming: [AgentMessage]) -> [AgentMessage] {
        var seen = Set<String>()
        var reversedUnique: [AgentMessage] = []
        reversedUnique.reserveCapacity(incoming.count)

        for message in incoming.reversed() {
            guard seen.insert(message.id).inserted else {
                continue
            }
            reversedUnique.append(message)
        }

        return reversedUnique.reversed()
    }
}
