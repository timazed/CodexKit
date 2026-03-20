import CodexKit
import Foundation
#if os(iOS)
import HealthKit
import UserNotifications
#endif

#if os(iOS)
@MainActor
extension AgentDemoViewModel {
    func requestHealthKitAuthorization() async throws -> Bool {
        guard let stepType = HKObjectType.quantityType(forIdentifier: .stepCount) else {
            return false
        }

        return try await withCheckedThrowingContinuation { continuation in
            healthStore.requestAuthorization(toShare: [], read: [stepType]) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: success)
            }
        }
    }

    func requestNotificationAuthorization() async -> Bool {
        let authorizationStatus = await currentNotificationAuthorizationStatus()
        switch authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            return (try? await withCheckedThrowingContinuation { continuation in
                notificationCenter.requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    continuation.resume(returning: granted)
                }
            }) ?? false
        @unknown default:
            return false
        }
    }

    func currentNotificationAuthorizationStatus() async -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            notificationCenter.getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }

    func fetchTodayStepCount() async throws -> Int {
        guard let quantityType = HKObjectType.quantityType(forIdentifier: .stepCount) else {
            return 0
        }

        let startOfDay = Calendar.current.startOfDay(for: Date())
        let predicate = HKQuery.predicateForSamples(
            withStart: startOfDay,
            end: Date(),
            options: .strictStartDate
        )

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: quantityType,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, result, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                let total = result?.sumQuantity()?.doubleValue(for: HKUnit.count()) ?? 0
                continuation.resume(returning: Int(total.rounded()))
            }
            healthStore.execute(query)
        }
    }

    func scheduleStepReminders() async {
        let identifiers = Self.healthReminderSchedule.map { schedule in
            "\(Self.healthReminderIdentifierPrefix)-\(schedule.hour)-\(schedule.minute)"
        }
        notificationCenter.removePendingNotificationRequests(withIdentifiers: identifiers)

        guard !hasMetDailyGoal else {
            return
        }

        let calendar = Calendar.current
        let now = Date()
        let remaining = remainingStepCount
        let title = "Health Coach Checkpoint"
        let body = await reminderNotificationBody(remaining: remaining)

        for schedule in Self.healthReminderSchedule {
            guard let reminderDate = calendar.date(
                bySettingHour: schedule.hour,
                minute: schedule.minute,
                second: 0,
                of: now
            ), reminderDate > now else {
                continue
            }

            let components = calendar.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: reminderDate
            )
            let trigger = UNCalendarNotificationTrigger(
                dateMatching: components,
                repeats: false
            )

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default

            let identifier = "\(Self.healthReminderIdentifierPrefix)-\(schedule.hour)-\(schedule.minute)"
            let request = UNNotificationRequest(
                identifier: identifier,
                content: content,
                trigger: trigger
            )

            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    notificationCenter.add(request) { error in
                        if let error {
                            continuation.resume(throwing: error)
                            return
                        }
                        continuation.resume(returning: ())
                    }
                }
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func reminderNotificationBody(remaining: Int) async -> String {
        let cacheKey = Self.reminderCopyCacheKey(
            remaining: remaining,
            goal: dailyStepGoal,
            toneMode: healthCoachToneMode
        )
        if let cachedAIReminderBody,
           let cachedAIReminderKey,
           let cachedAIReminderGeneratedAt,
           cachedAIReminderKey == cacheKey,
           Date().timeIntervalSince(cachedAIReminderGeneratedAt) < 3600 {
            return cachedAIReminderBody
        }

        guard session != nil else {
            return Self.fallbackReminderBody(
                remaining: remaining,
                toneMode: healthCoachToneMode
            )
        }

        do {
            let threadID = try await ensureHealthCoachThreadID()
            let stream = try await runtime.sendMessage(
                UserMessageRequest(
                    text: """
                    Write one short local notification reminder line for a step-goal app.
                    Constraints:
                    - tone_mode: \(healthCoachToneMode.rawValue)
                    - steps_remaining: \(remaining)
                    - goal: \(dailyStepGoal)
                    - Address the user as "you" only (no names or nicknames).
                    - One sentence, max 18 words.
                    - No emojis.
                    - No quotes around the result.
                    Return only the reminder text.
                    """
                ),
                in: threadID
            )

            var generatedText = ""
            for try await event in stream {
                switch event {
                case let .assistantMessageDelta(_, _, delta):
                    generatedText.append(delta)

                case let .messageCommitted(message):
                    guard message.role == .assistant else {
                        continue
                    }
                    generatedText = message.displayText

                case .turnCompleted:
                    threads = await runtime.threads()

                default:
                    break
                }
            }

            let cleaned = generatedText
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
            if !cleaned.isEmpty {
                cachedAIReminderBody = cleaned
                cachedAIReminderKey = cacheKey
                cachedAIReminderGeneratedAt = Date()
                return cleaned
            }
        } catch {
            Self.logger.error("Failed to generate AI reminder copy: \(error.localizedDescription, privacy: .public)")
        }

        return Self.fallbackReminderBody(
            remaining: remaining,
            toneMode: healthCoachToneMode
        )
    }
}
#endif
