import CodexKit
import CodexKitUI
import Foundation
import OSLog
import Observation
#if os(iOS)
import HealthKit
import UserNotifications
#endif

@MainActor
@Observable
final class AgentDemoViewModel: @unchecked Sendable {
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

    var session: ChatGPTSession?
    var threads: [AgentThread] = []
    var messages: [AgentMessage] = []
    var streamingText = ""
    var lastError: String?
    var isAuthenticating = false
    var pendingComposerImages: [AgentImageAttachment] = []
    var composerText = ""
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
        stateURL: URL?,
        keychainAccount: String,
        approvalInbox: ApprovalInbox,
        deviceCodePromptCoordinator: DeviceCodePromptCoordinator = DeviceCodePromptCoordinator()
    ) {
        self.runtime = runtime
        self.model = model
        self.enableWebSearch = enableWebSearch
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

    func restore() async {
        do {
            _ = try await runtime.restore()
            await registerDemoTool()
            await refreshSnapshot()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func signIn(using authenticationMethod: DemoAuthenticationMethod) async {
        guard !isAuthenticating else {
            return
        }

        isAuthenticating = true
        lastError = nil
        runtime = AgentDemoRuntimeFactory.makeRuntime(
            authenticationMethod: authenticationMethod,
            model: model,
            enableWebSearch: enableWebSearch,
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
            session = try await runtime.signIn()
            await refreshSnapshot()
            if healthCoachInitialized {
                await refreshHealthCoachProgress()
            }
        } catch {
            await deviceCodePromptCoordinator.clear()
            await refreshSnapshot()
            lastError = error.localizedDescription
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
            lastError = error.localizedDescription
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

    func personaSummary(for thread: AgentThread?) -> String? {
        guard let layers = thread?.personaStack?.layers,
              !layers.isEmpty else {
            return nil
        }

        return layers.map(\.name).joined(separator: ", ")
    }

    func activateThread(id: String) async {
        activeThreadID = id
        messages = await runtime.messages(for: id)
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
        lastError = message
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
            lastError = error.localizedDescription
        }
    }

    func refreshSnapshot() async {
        session = await runtime.currentSession()
        guard session != nil else {
            clearConversationSnapshot()
            return
        }

        threads = await runtime.threads()

        let selectedThreadID = activeThreadID
        if let selectedThreadID,
           threads.contains(where: { $0.id == selectedThreadID }) {
            messages = await runtime.messages(for: selectedThreadID)
            return
        }

        if let firstThread = threads.first {
            activeThreadID = firstThread.id
            messages = await runtime.messages(for: firstThread.id)
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
        activeThreadID = nil
    }
}
