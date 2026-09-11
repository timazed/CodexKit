import Foundation

/// Adapts the provider's flat, discriminated JSON to the runtime's event enum.
/// Payload structs let Decodable validate each event's fields independently.
struct CodexResponsesEventPayload: Decodable {
    let type: String
    let event: CodexResponsesStreamEvent
    let logsResponsePayload: Bool

    private enum CodingKeys: String, CodingKey {
        case type
        case sequenceNumber = "sequence_number"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        let discriminator = ResponsesEventType(rawValue: type)
        logsResponsePayload = discriminator?.logsResponsePayload == true
        let sequenceNumber = discriminator == .rateLimits
            ? nil : try container.decodeIfPresent(Int.self, forKey: .sequenceNumber)
        event = .init(kind: try Self.decodeKind(discriminator, from: decoder), sequenceNumber: sequenceNumber)
    }

    private static func decodeKind(_ type: ResponsesEventType?, from decoder: Decoder) throws -> CodexResponsesStreamEvent.Kind {
        switch type {
        case .rateLimits:
            let object = try [String: JSONValue](from: decoder)
            return .rateLimits([CodexRateLimitParser.event(object)])
        case .outputItemAdded:
            return try ItemPayload(from: decoder).item?.startedProgress.map(CodexResponsesStreamEvent.Kind.progress) ?? .other
        case .outputItemDone:
            let payload = try ItemPayload(from: decoder)
            guard let item = payload.item else { return .other }
            return .outputItem(item, outputIndex: payload.outputIndex ?? 0)
        case .outputTextDelta:
            return try TextPayload(from: decoder).delta.map(CodexResponsesStreamEvent.Kind.assistantTextDelta) ?? .other
        case .reasoningSummaryTextDelta:
            let payload = try ReasoningPayload(from: decoder)
            guard let itemID = payload.itemID, let delta = payload.delta else { return .other }
            return .progress(.reasoningSummaryDelta(itemID: itemID, summaryIndex: payload.summaryIndex ?? 0, delta: delta))
        case .webSearchInProgress:
            return try SearchPayload(from: decoder).progress(status: .inProgress)
        case .webSearchSearching:
            return try SearchPayload(from: decoder).progress(status: .searching)
        case .webSearchCompleted:
            return try SearchPayload(from: decoder).progress(status: .completed)
        case .created:
            return .responseCreated(responseID: try ResponsePayload(from: decoder).response?.id)
        case .completed:
            let response = try ResponsePayload(from: decoder).response
            return .completed(response?.usage?.assistantUsage ?? AgentUsage(), responseID: response?.id)
        case .failed:
            let response = try ResponsePayload(from: decoder).response
            return .failed(.init(code: .responsesStreamFailed,
                message: response?.error?.message ?? "The ChatGPT responses stream failed.",
                http: .init(statusCode: 200, providerCode: response?.error?.code, providerType: response?.error?.type)),
                responseID: response?.id)
        case .incomplete:
            let response = try ResponsePayload(from: decoder).response
            let reason = response?.incompleteDetails?.reason ?? "unknown"
            return .failed(.init(code: .responsesStreamIncomplete,
                message: "The ChatGPT responses stream completed early: \(reason)."), responseID: response?.id)
        case nil:
            return .other
        }
    }

    private struct ItemPayload: Decodable {
        let item: StreamItem?
        let outputIndex: Int?

        enum CodingKeys: String, CodingKey {
            case item
            case outputIndex = "output_index"
        }
    }

    private struct TextPayload: Decodable {
        let delta: String?
    }

    private struct ReasoningPayload: Decodable {
        let itemID: String?
        let delta: String?
        let summaryIndex: Int?

        enum CodingKeys: String, CodingKey {
            case delta
            case itemID = "item_id"
            case summaryIndex = "summary_index"
        }
    }

    private struct SearchPayload: Decodable {
        let itemID: String?

        enum CodingKeys: String, CodingKey { case itemID = "item_id" }

        func progress(status: AgentWebSearchStatus) -> CodexResponsesStreamEvent.Kind {
            guard let itemID else { return .other }
            return .progress(.webSearch(itemID: itemID, status: status, action: nil))
        }
    }

    private struct ResponsePayload: Decodable {
        let response: StreamResponsePayload?
    }
}
