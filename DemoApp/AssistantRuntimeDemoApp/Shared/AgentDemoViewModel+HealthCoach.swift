import CodexKit
import Foundation
#if os(iOS)
import HealthKit
#endif

enum HealthCoachToneMode: String, CaseIterable, Identifiable {
    case hardcorePersonal
    case firmCoach

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hardcorePersonal:
            "Hardcore Personal"
        case .firmCoach:
            "Firm Coach"
        }
    }

    var summary: String {
        switch self {
        case .hardcorePersonal:
            "Blunt, high-pressure accountability."
        case .firmCoach:
            "Direct coaching without harsh language."
        }
    }
}

@MainActor
extension AgentDemoViewModel {
    nonisolated static let healthCoachThreadTitle = "Health Coach"
    nonisolated static let healthReminderIdentifierPrefix = "health-coach-reminder"
    nonisolated static let healthReminderSchedule: [(hour: Int, minute: Int)] = [
        (10, 0),
        (13, 0),
        (16, 0),
        (19, 0),
    ]

    func initializeHealthCoachIfNeeded() async {
        guard !healthCoachInitialized else {
            return
        }

        healthCoachInitialized = true
        await requestHealthCoachPermissions()
        await refreshHealthCoachProgress()
    }

    func requestHealthCoachPermissions() async {
#if os(iOS)
        guard HKHealthStore.isHealthDataAvailable() else {
            healthKitAuthorized = false
            notificationAuthorized = false
            healthCoachFeedback = "Health data is unavailable on this device."
            return
        }

        do {
            healthKitAuthorized = try await requestHealthKitAuthorization()
            if healthKitAuthorized {
                lastError = nil
            }
        } catch {
            healthKitAuthorized = false
            reportError(error)
        }

        notificationAuthorized = await requestNotificationAuthorization()
        await updateReminderScheduleIfPossible()
        if healthKitAuthorized {
            await refreshHealthCoachProgress()
        } else {
            healthCoachFeedback = "Health permission is required to load today’s steps."
        }
#else
        healthKitAuthorized = false
        notificationAuthorized = false
        healthCoachFeedback = "Health Coach is currently available on iOS only."
#endif
    }

    func refreshHealthCoachProgress() async {
#if os(iOS)
        guard healthKitAuthorized else {
            healthCoachFeedback = "Grant Health access to start tracking your steps."
            return
        }

        isRefreshingHealthCoach = true
        defer {
            isRefreshingHealthCoach = false
        }

        do {
            todayStepCount = try await fetchTodayStepCount()
            healthLastUpdatedAt = Date()
            lastError = nil
            await updateReminderScheduleIfPossible()
            await refreshAICoachFeedback()
        } catch {
            reportError(error)
        }
#else
        healthCoachFeedback = "Health Coach is currently available on iOS only."
#endif
    }

    func adjustDailyStepGoal(by delta: Int) async {
        let updated = max(1_000, min(50_000, dailyStepGoal + delta))
        dailyStepGoal = updated
        await updateReminderScheduleIfPossible()
        await refreshAICoachFeedback()
    }

    func setHealthCoachToneMode(_ toneMode: HealthCoachToneMode) async {
        guard healthCoachToneMode != toneMode else {
            return
        }

        healthCoachToneMode = toneMode
        cachedAICoachFeedbackKey = nil
        cachedAICoachFeedbackGeneratedAt = nil

        guard let healthCoachThreadID else {
            await updateReminderScheduleIfPossible()
            await refreshAICoachFeedback()
            return
        }

        do {
            try await runtime.setPersonaStack(
                currentHealthCoachPersona(),
                for: healthCoachThreadID
            )
            threads = await runtime.threads()
            lastError = nil
        } catch {
            reportError(error)
        }

        await updateReminderScheduleIfPossible()
        await refreshAICoachFeedback()
    }

    func askAICoachForStepFeedback() async {
        await refreshAICoachFeedback(force: true)
    }

    func refreshAICoachFeedback(force: Bool = false) async {
        guard healthKitAuthorized else {
            healthCoachFeedback = "Grant Health access to start tracking your steps."
            return
        }

        guard session != nil else {
            healthCoachFeedback = "Sign in to get proactive AI coach feedback."
            return
        }

        let cacheKey = Self.coachFeedbackCacheKey(
            steps: todayStepCount,
            goal: dailyStepGoal,
            toneMode: healthCoachToneMode
        )
        if !force,
           let cachedAICoachFeedbackKey,
           let cachedAICoachFeedbackGeneratedAt,
           cachedAICoachFeedbackKey == cacheKey,
           Date().timeIntervalSince(cachedAICoachFeedbackGeneratedAt) < 600 {
            return
        }

        isAskingHealthCoach = true
        if healthCoachFeedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || force {
            healthCoachFeedback = "Coach is updating..."
        }

        defer {
            isAskingHealthCoach = false
        }

        do {
            let threadID = try await ensureHealthCoachThreadID()
            let stream = try await runtime.streamMessage(
                UserMessageRequest(
                    text: """
                    Daily step check-in:
                    - tone_mode: \(healthCoachToneMode.rawValue)
                    - steps_today: \(todayStepCount)
                    - goal: \(dailyStepGoal)
                    - remaining: \(remainingStepCount)

                    Give:
                    1) one short accountability line addressing me directly as "you"
                    2) one concrete 30-minute action
                    3) if goal completed, one short earned-praise line
                    Keep it under 70 words.
                    """
                ),
                in: threadID
            )

            var streamedResponse = ""
            for try await event in stream {
                switch event {
                case let .assistantMessageDelta(_, _, delta):
                    streamedResponse.append(delta)
                    healthCoachFeedback = streamedResponse

                case let .messageCommitted(message):
                    guard message.role == .assistant else {
                        continue
                    }
                    healthCoachFeedback = message.displayText

                case .turnCompleted:
                    threads = await runtime.threads()
                    cachedAICoachFeedbackKey = cacheKey
                    cachedAICoachFeedbackGeneratedAt = Date()
                    lastError = nil

                case let .turnFailed(error):
                    lastError = error.message

                default:
                    break
                }
            }
        } catch {
            reportError(error)
        }
    }

    func ensureHealthCoachThreadID() async throws -> String {
        let persona = currentHealthCoachPersona()

        if let healthCoachThreadID {
            try await runtime.setPersonaStack(persona, for: healthCoachThreadID)
            return healthCoachThreadID
        }

        let existingThreads = await runtime.threads()
        if let existing = existingThreads.first(where: { $0.title == Self.healthCoachThreadTitle }) {
            try await runtime.setPersonaStack(persona, for: existing.id)
            healthCoachThreadID = existing.id
            threads = await runtime.threads()
            return existing.id
        }

        let thread = try await runtime.createThread(
            title: Self.healthCoachThreadTitle,
            personaStack: persona
        )
        healthCoachThreadID = thread.id
        threads = await runtime.threads()
        return thread.id
    }

    func currentHealthCoachPersona() -> AgentPersonaStack {
        Self.healthCoachPersona(toneMode: healthCoachToneMode)
    }

    nonisolated static func healthCoachPersona(
        toneMode: HealthCoachToneMode
    ) -> AgentPersonaStack {
        let styleInstructions: String

        switch toneMode {
        case .hardcorePersonal:
            styleInstructions = """
            Be blunt, forceful, and no-nonsense. Push accountability hard, call out excuses directly, and give action commands.
            Address the user directly as "you."
            Never use slurs, body-shaming labels, identity-targeted insults, or humiliation.
            If the goal is completed, switch to brief earned praise: "Well done, you pushed through."
            """

        case .firmCoach:
            styleInstructions = """
            Be firm, direct, and practical. Keep pressure on execution with concise next actions.
            Address the user directly as "you."
            Avoid insults and avoid coddling.
            If the goal is completed, give brief earned praise.
            """
        }

        return AgentPersonaStack(layers: [
            .init(
                name: "domain",
                instructions: "You are a step-goal accountability coach for a mobile health app."
            ),
            .init(
                name: "style",
                instructions: styleInstructions
            ),
        ])
    }

    nonisolated static func coachFeedbackCacheKey(
        steps: Int,
        goal: Int,
        toneMode: HealthCoachToneMode
    ) -> String {
        "\(toneMode.rawValue)-\(steps)-\(goal)-\(max(goal - steps, 0))"
    }

    nonisolated static func fallbackReminderBody(
        remaining: Int,
        toneMode: HealthCoachToneMode
    ) -> String {
        if remaining <= 0 {
            return "You are on pace. Stay consistent and finish strong."
        }

        switch toneMode {
        case .hardcorePersonal:
            return "You still owe \(remaining) steps today. Move now and close it."
        case .firmCoach:
            return "\(remaining) steps remain. Take a focused walking block now."
        }
    }

    nonisolated static func reminderCopyCacheKey(
        remaining: Int,
        goal: Int,
        toneMode: HealthCoachToneMode
    ) -> String {
        let ratio = goal > 0 ? Double(remaining) / Double(goal) : 0
        let band: String
        switch ratio {
        case ...0:
            band = "complete"
        case ..<0.2:
            band = "close"
        case ..<0.6:
            band = "mid"
        default:
            band = "far"
        }
        return "\(toneMode.rawValue)-\(band)"
    }

    func updateReminderScheduleIfPossible() async {
#if os(iOS)
        guard notificationAuthorized else {
            return
        }
        await scheduleStepReminders()
#endif
    }
}
