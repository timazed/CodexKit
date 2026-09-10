import CodexKit
import Foundation

enum DemoMemoryExamples {
    static let namespace = "demo-assistant"
    static let healthCoachScope: MemoryScope = "feature:health-coach"
    static let travelPlannerScope: MemoryScope = "feature:travel-planner"

    static let guidedDraft = MemoryDraft(
        summary: "Health Coach should use blunt accountability when the user is behind on steps.",
        evidence: ["The user responds better to direct push language than soft encouragement."],
        importance: 0.95,
        tags: ["tone", "steps"],
        relatedIDs: ["health-goal-10000"],
        dedupeKey: "health-coach-direct-accountability"
    )

    static let rawRecord = MemoryRecord(
        namespace: namespace,
        scope: travelPlannerScope,
        category: "preference",
        summary: "Travel Planner should keep itineraries compact, walkable, and transit-aware.",
        evidence: ["The demo works best when travel plans stay practical for mobile users."],
        importance: 0.82,
        tags: ["travel", "logistics"],
        relatedIDs: ["travel-style-compact"],
        dedupeKey: "travel-planner-compact-itinerary"
    )

    static let previewRequestText = "How should the assistant behave for the health coach and travel planner demos?"
    static let previewBudget = MemoryReadBudget(maxItems: 4, maxCharacters: 500)
    static let automaticCaptureTranscript = """
    User: I respond better when the health coach is direct and blunt if I am behind on steps.
    Assistant: Understood. I will stop soft-pedaling reminders and push harder when you are off pace.
    User: For travel planning, keep itineraries compact, walkable, and transit-aware. I hate sprawling plans.
    """
    static let automaticPolicyPrompt = "When I fall behind on steps, drop the sugar-coating and be direct with me."

    static let guidedDefaults = MemoryWriterDefaults(
        namespace: namespace,
        scope: healthCoachScope,
        category: "preference",
        tags: ["demo", "guided"],
        relatedIDs: ["demo-memory"],
        status: .active
    )

    static let previewContext = AgentMemoryContext(
        namespace: namespace,
        scopes: [healthCoachScope, travelPlannerScope],
        readBudget: previewBudget
    )
}
