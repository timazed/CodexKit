import Combine
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

struct DemoCatalog {
    let supportPersona: AgentPersonaStack
    let plannerPersona: AgentPersonaStack
    let reviewerOverridePersona: AgentPersonaStack
    let healthCoachToolName: String
    let travelPlannerToolName: String
    let healthCoachSkill: AgentSkill
    let travelPlannerSkill: AgentSkill

    init() {
        supportPersona = AgentPersonaStack(layers: [
            .init(
                name: "domain",
                instructions: "You are an expert customer support agent for a shipping app."
            ),
            .init(
                name: "style",
                instructions: "Be concise, calm, and action-oriented."
            ),
        ])
        plannerPersona = AgentPersonaStack(layers: [
            .init(
                name: "planner",
                instructions: "Act as a careful technical planner. Focus on tradeoffs and implementation sequencing."
            ),
        ])
        reviewerOverridePersona = AgentPersonaStack(layers: [
            .init(
                name: "reviewer",
                instructions: "For this reply only, act as a strict reviewer and call out risks first."
            ),
        ])

        healthCoachToolName = "health_coach_fetch_progress"
        travelPlannerToolName = "travel_planner_build_day_plan"
        healthCoachSkill = AgentSkill(
            id: "health_coach",
            name: "Health Coach",
            instructions: "You are a health coach focused on daily step goals and execution. For every user turn, call the \(healthCoachToolName) tool exactly once before your final reply, then provide one practical walking plan and one accountability line.",
            executionPolicy: .init(
                allowedToolNames: [healthCoachToolName],
                requiredToolNames: [healthCoachToolName],
                maxToolCalls: 1
            )
        )
        travelPlannerSkill = AgentSkill(
            id: "travel_planner",
            name: "Travel Planner",
            instructions: "You are a travel planning assistant for mobile users. Provide concise day-by-day itineraries, practical logistics, and a compact packing checklist.",
            executionPolicy: .init(
                allowedToolNames: [travelPlannerToolName],
                maxToolCalls: 1
            )
        )
    }
}

struct DemoDiagnostics {
    private let developerLoggingDefaultsKey = "AssistantRuntimeDemoApp.developerLoggingEnabled"
    private let logger = Logger(
        subsystem: "ai.assistantruntime.demoapp",
        category: "DemoTool"
    )

    func initialDeveloperLoggingEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        if userDefaults.object(forKey: developerLoggingDefaultsKey) != nil {
            return userDefaults.bool(forKey: developerLoggingDefaultsKey)
        }
#if DEBUG
        return true
#else
        return false
#endif
    }

    func persistDeveloperLoggingEnabled(
        _ enabled: Bool,
        userDefaults: UserDefaults = .standard
    ) {
        userDefaults.set(enabled, forKey: developerLoggingDefaultsKey)
    }

    func isCancellationError(_ error: Error) -> Bool {
        error is CancellationError
    }

    func log(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        print("[CodexKit Demo] \(message)")
    }

    func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        print("[CodexKit Demo][Error] \(message)")
    }
}

@MainActor
@Observable
final class AgentDemoViewModel: @unchecked Sendable {
    var session: ChatGPTSession?
    var threads: [AgentThread] = []
    var messages: [AgentMessage] = []
    var streamingText = ""
    var lastError: String?
    var showResolvedInstructionsDebug = false
    var developerLoggingEnabled: Bool {
        didSet {
            diagnostics.persistDeveloperLoggingEnabled(developerLoggingEnabled)
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
    var activeThreadContextState: AgentThreadContextState?
    var isCompactingThreadContext = false
    var observedThread: AgentThread?
    var observedMessages: [AgentMessage] = []
    var observedThreadSummary: AgentThreadSummary?
    var observedThreadContextState: AgentThreadContextState?
    var activeThreadContextUsage: AgentThreadContextUsage?
    var observedThreadContextUsage: AgentThreadContextUsage?

    let approvalInbox: ApprovalInbox
    let deviceCodePromptCoordinator: DeviceCodePromptCoordinator
    let model: String
    let enableWebSearch: Bool
    let stateURL: URL?
    let keychainAccount: String
    let catalog: DemoCatalog
    let diagnostics: DemoDiagnostics
    let toolOutputFactory: DemoToolOutputFactory
    let healthCoachDesign: DemoHealthCoachDesign

    var runtime: AgentRuntime
    var activeThreadID: String?
    var healthCoachThreadID: String?
    @ObservationIgnored
    var runtimeObservationCancellables: Set<AnyCancellable> = []
    @ObservationIgnored
    var activeThreadObservationCancellables: Set<AnyCancellable> = []

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
        self.catalog = DemoCatalog()
        self.diagnostics = DemoDiagnostics()
        self.toolOutputFactory = DemoToolOutputFactory()
        self.healthCoachDesign = DemoHealthCoachDesign()
        self.runtime = runtime
        self.model = model
        self.enableWebSearch = enableWebSearch
        self.reasoningEffort = reasoningEffort
        self.developerLoggingEnabled = diagnostics.initialDeveloperLoggingEnabled()
        self.stateURL = stateURL
        self.keychainAccount = keychainAccount
        self.approvalInbox = approvalInbox
        self.deviceCodePromptCoordinator = deviceCodePromptCoordinator
        configureRuntimeObservationBindings()
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
}
