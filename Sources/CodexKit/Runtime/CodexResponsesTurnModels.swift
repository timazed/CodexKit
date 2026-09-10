import Foundation

enum TurnPassDisposition {
    case needsAnotherPass
    case completed

    func merging(with other: TurnPassDisposition) -> TurnPassDisposition {
        switch (self, other) {
        case (.needsAnotherPass, _), (_, .needsAnotherPass):
            return .needsAnotherPass
        case (.completed, .completed):
            return .completed
        }
    }
}
struct TurnRunState {
    var workingHistory: [WorkingHistoryItem]
    var aggregateUsage = AgentUsage()
    var pendingResponseItems: [PendingResponseItem] = []
    var pendingFunctionCalls: [FunctionCallRecord] = []
    var pendingToolOutputs: [WorkingHistoryItem] = []
    var pendingToolImages: [AgentImageAttachment] = []
    var pendingToolFallbackTexts: [String] = []
    var structuredParser = CodexResponsesStructuredStreamParser()
    var pendingStructuredOutputMetadata: AgentStructuredOutputMetadata?
    var toolCallsByID: [String: FunctionCallRecord] = [:]
    var hasToolActivity = false

    mutating func beginAttempt() {
        structuredParser = CodexResponsesStructuredStreamParser()
        pendingStructuredOutputMetadata = nil
        pendingFunctionCalls.removeAll(keepingCapacity: true)
        pendingResponseItems.removeAll(keepingCapacity: true)
        pendingToolOutputs.removeAll(keepingCapacity: true)
    }
}

struct PendingResponseItem {
    let outputIndex: Int
    let sequenceNumber: Int?
    let arrivalOrder: Int
    let value: JSONValue
}

struct RetryAttemptState {
    // Only in memory, for renewing the actual credential used after host authorization/backoff.
    var accessTokenUsed: String?
    var hasAssistantDelta = false
    var hasNonReplayableOutput = false

    var hasVisibleOutput: Bool {
        hasAssistantDelta || hasNonReplayableOutput
    }

    mutating func record(_ eventResult: StreamEventResult) {
        hasAssistantDelta = hasAssistantDelta || eventResult.emittedAssistantDelta
        hasNonReplayableOutput = hasNonReplayableOutput || eventResult.emittedNonReplayableOutput
    }
}

struct RetryDecision {
    let shouldRetry: Bool
    let retryableError: Bool
    let blockedBy: String?
}

struct StreamEventResult {
    let emittedAssistantDelta: Bool
    let emittedNonReplayableOutput: Bool
    let passDisposition: TurnPassDisposition

    static let none = StreamEventResult(
        emittedAssistantDelta: false,
        emittedNonReplayableOutput: false,
        passDisposition: .completed
    )

    static let assistantDelta = StreamEventResult(
        emittedAssistantDelta: true,
        emittedNonReplayableOutput: false,
        passDisposition: .completed
    )

    static let assistantMessage = StreamEventResult(
        emittedAssistantDelta: false,
        emittedNonReplayableOutput: true,
        passDisposition: .completed
    )

    static let toolCall = StreamEventResult(
        emittedAssistantDelta: false,
        emittedNonReplayableOutput: true,
        passDisposition: .needsAnotherPass
    )
}
