import CodexKit
import Foundation

private struct HealthCoachToolSnapshot: Sendable {
    let stepsToday: Int
    let dailyGoal: Int
    let remainingSteps: Int
    let hoursLeftToday: Int
    let healthKitAuthorized: Bool
}

@MainActor
extension AgentDemoViewModel {
    func registerDemoSkills() async {
        do {
            try await runtime.replaceSkill(Self.healthCoachSkill)
            try await runtime.replaceSkill(Self.travelPlannerSkill)
            developerLog("Registered demo skills: \(Self.healthCoachSkill.id), \(Self.travelPlannerSkill.id)")
        } catch {
            reportError(error)
        }
    }

    func registerDemoTool() async {
        do {
            let healthCoachDefinition = ToolDefinition(
                name: Self.healthCoachToolName,
                description: "Fetch a live health-coach progress snapshot from HealthKit-aware app state.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([:]),
                ])
            )

            let travelPlannerDefinition = ToolDefinition(
                name: Self.travelPlannerToolName,
                description: "Build a compact deterministic day-by-day travel plan.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "destination": .object([
                            "type": .string("string"),
                            "description": .string("Trip destination."),
                        ]),
                        "trip_days": .object([
                            "type": .string("number"),
                            "description": .string("Number of trip days."),
                        ]),
                        "budget_level": .object([
                            "type": .string("string"),
                            "description": .string("Budget level: low, medium, or high."),
                        ]),
                        "companions": .object([
                            "type": .string("string"),
                            "description": .string("Who is traveling, for example solo, couple, or family."),
                        ]),
                    ]),
                    "required": .array([
                        .string("destination"),
                    ]),
                ])
            )

            try await registerTool(healthCoachDefinition) { [weak self] invocation, _ in
                guard let self else {
                    return .failure(invocation: invocation, message: "Health coach context is unavailable.")
                }
                let snapshot = await self.captureHealthCoachToolSnapshot()
                return Self.makeHealthCoachProgress(
                    invocation: invocation,
                    snapshot: snapshot
                )
            }
            try await registerTool(travelPlannerDefinition) { invocation, _ in
                Self.makeTravelDayPlan(invocation: invocation)
            }
            developerLog(
                "Registered demo tools: \(Self.healthCoachToolName), \(Self.travelPlannerToolName)"
            )
        } catch {
            reportError(error)
        }
    }

    private func registerTool(
        _ definition: ToolDefinition,
        execute: @escaping @Sendable (ToolInvocation, ToolExecutionContext) async throws -> ToolResultEnvelope
    ) async throws {
        try await runtime.replaceTool(definition, executor: AnyToolExecutor { invocation, context in
            Self.logger.info(
                "Executing tool \(invocation.toolName, privacy: .public) with arguments: \(String(describing: invocation.arguments), privacy: .public)"
            )
            let result = try await execute(invocation, context)
            Self.logger.info(
                "Tool \(invocation.toolName, privacy: .public) returned: \(result.primaryText ?? "<no text result>", privacy: .public)"
            )
            return result
        })
    }

    private func captureHealthCoachToolSnapshot() async -> HealthCoachToolSnapshot {
        var stepsToday = todayStepCount
#if os(iOS)
        if healthKitAuthorized,
           let refreshedStepCount = try? await fetchTodayStepCount() {
            stepsToday = refreshedStepCount
            todayStepCount = refreshedStepCount
            healthLastUpdatedAt = Date()
        }
#endif
        let safeGoal = max(dailyStepGoal, 1_000)
        let remainingSteps = max(safeGoal - stepsToday, 0)
        let endOfDay = Calendar.current.startOfDay(for: Date()).addingTimeInterval(86_400)
        let hoursLeftToday = max(Int(ceil(endOfDay.timeIntervalSinceNow / 3600)), 1)

        return HealthCoachToolSnapshot(
            stepsToday: stepsToday,
            dailyGoal: safeGoal,
            remainingSteps: remainingSteps,
            hoursLeftToday: hoursLeftToday,
            healthKitAuthorized: healthKitAuthorized
        )
    }

    private nonisolated static func makeHealthCoachProgress(
        invocation: ToolInvocation,
        snapshot: HealthCoachToolSnapshot
    ) -> ToolResultEnvelope {
        let freshness = snapshot.healthKitAuthorized ? "live_or_cached_healthkit" : "app_cached_only"

        return .success(
            invocation: invocation,
            text: """
            health_progress[stepsToday=\(snapshot.stepsToday), dailyGoal=\(snapshot.dailyGoal), remainingSteps=\(snapshot.remainingSteps), hoursLeftToday=\(snapshot.hoursLeftToday), healthKitAuthorized=\(snapshot.healthKitAuthorized), freshness=\(freshness)]
            """
        )
    }

    nonisolated static func makeTravelDayPlan(invocation: ToolInvocation) -> ToolResultEnvelope {
        guard case let .object(arguments) = invocation.arguments else {
            return .failure(
                invocation: invocation,
                message: "The travel planner tool expected object arguments."
            )
        }

        let destination = arguments["destination"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let tripDays = max(Int(arguments["trip_days"]?.numberValue ?? 3), 1)
        let budget = arguments["budget_level"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? "medium"
        let companions = arguments["companions"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? "solo"

        guard let destination, !destination.isEmpty else {
            return .failure(invocation: invocation, message: "destination is required.")
        }

        let planLines = (1 ... min(tripDays, 10)).map { day in
            "day\(day):arrival_walk=\(budget == "high" ? "taxi+priority-pass" : "public-transit"),focus=\(companions == "family" ? "kid-friendly highlight + early dinner" : "local highlight + flexible dinner")"
        }

        return .success(
            invocation: invocation,
            text: """
            travel_day_plan[destination=\(destination), tripDays=\(tripDays), budget=\(budget), companions=\(companions), plan=\(planLines.joined(separator: " | "))]
            """
        )
    }
}

private extension JSONValue {
    var numberValue: Double? {
        guard case let .number(value) = self else {
            return nil
        }
        return value
    }

}
