import Foundation

struct CodexResponsesRecoveryPayload: Codable, Sendable {
    let responseID: String
    let turnStartedAt: Date
    let instructions: String
    let threadConfiguration: AgentThreadConfiguration
    let responseFormat: AgentStructuredOutputFormat?
    let streamedStructuredOutput: AgentStreamedStructuredOutputRequest?
    let workingHistory: [JSONValue]
    let previousResponseID: String?
    let aggregateUsage: AgentUsage
    let pendingToolFallbackTexts: [String]
    let pendingStructuredOutputMetadata: AgentStructuredOutputMetadata?

    enum CodingKeys: String, CodingKey {
        case responseID = "response_id"
        case turnStartedAt = "turn_started_at"
        case instructions
        case threadConfiguration = "thread_configuration"
        case responseFormat = "response_format"
        case streamedStructuredOutput = "streamed_structured_output"
        case workingHistory = "working_history"
        case previousResponseID = "previous_response_id"
        case aggregateUsage = "aggregate_usage"
        case pendingToolFallbackTexts = "pending_tool_fallback_texts"
        case pendingStructuredOutputMetadata = "pending_structured_output_metadata"
    }

    init(
        responseID: String,
        turnStartedAt: Date,
        instructions: String,
        threadConfiguration: AgentThreadConfiguration,
        responseContract: AgentResponseContract?,
        state: TurnRunState
    ) throws {
        self.responseID = responseID
        self.turnStartedAt = turnStartedAt
        self.instructions = instructions
        self.threadConfiguration = threadConfiguration
        self.responseFormat = responseContract?.textFormat
        self.streamedStructuredOutput = responseContract?.streamedRequest
        self.workingHistory = try CodexResponsesImageReferences.externalize(
            state.workingHistory.map(\.jsonValue)
        )
        self.previousResponseID = state.previousResponseID
        self.aggregateUsage = state.aggregateUsage
        self.pendingToolFallbackTexts = state.pendingToolFallbackTexts
        self.pendingStructuredOutputMetadata = state.pendingStructuredOutputMetadata
    }

    var responseContract: AgentResponseContract? {
        if let streamedStructuredOutput {
            return AgentResponseContract(
                format: streamedStructuredOutput.responseFormat,
                deliveryMode: .streaming(options: streamedStructuredOutput.options)
            )
        }
        return responseFormat.map {
            AgentResponseContract(format: $0, deliveryMode: .oneShot)
        }
    }

    func turnRunState(
        using workingHistoryAttachments: [AgentImageAttachment],
        pendingToolImages: [AgentImageAttachment]
    ) throws -> TurnRunState {
        var state = TurnRunState(
            workingHistory: try CodexResponsesImageReferences.restore(
                workingHistory,
                using: workingHistoryAttachments
            ).map(WorkingHistoryItem.raw),
            previousResponseID: previousResponseID
        )
        state.aggregateUsage = aggregateUsage
        state.pendingToolImages = pendingToolImages
        state.pendingToolFallbackTexts = pendingToolFallbackTexts
        state.pendingStructuredOutputMetadata = pendingStructuredOutputMetadata
        return state
    }

    var jsonValue: JSONValue {
        get throws {
            try JSONValue.encoding(self)
        }
    }

    init(jsonValue: JSONValue) throws {
        let data = try JSONEncoder().encode(jsonValue)
        self = try JSONDecoder().decode(Self.self, from: data)
    }
}
