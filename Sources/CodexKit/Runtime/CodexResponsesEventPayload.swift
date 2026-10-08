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
        if discriminator == .completed {
            let response = try ResponsePayload(from: decoder).response
            let usage = response?.usage?.assistantUsage ?? .unavailable()
            if response == nil {
                event = .init(kind: Self.failure(nil), sequenceNumber: sequenceNumber, terminalUsage: usage)
            } else if let status = response?.status, status != "completed" {
                event = .init(kind: Self.failure(response, incomplete: status == "incomplete"),
                    sequenceNumber: sequenceNumber, terminalUsage: usage)
            } else if response?.error != nil {
                event = .init(kind: Self.failure(response), sequenceNumber: sequenceNumber, terminalUsage: usage)
            } else if response?.incompleteDetails != nil {
                event = .init(kind: Self.failure(response, incomplete: true), sequenceNumber: sequenceNumber, terminalUsage: usage)
            } else {
                event = .init(kind: .completed(usage, responseID: response?.id),
                    sequenceNumber: sequenceNumber, completedOutput: try CompletionPayload(from: decoder).response?.output)
            }
        } else if discriminator == .failed || discriminator == .incomplete {
            let response = try ResponsePayload(from: decoder).response
            event = .init(kind: Self.failure(response, incomplete: discriminator == .incomplete),
                sequenceNumber: sequenceNumber, terminalUsage: response?.usage?.assistantUsage ?? .unavailable())
        } else {
            event = .init(kind: try Self.decodeKind(discriminator, from: decoder), sequenceNumber: sequenceNumber)
        }
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
            let payload = try TextPayload(from: decoder)
            guard let delta = payload.delta else { return .other }
            if let id = payload.itemID { return .identifiedTextDelta(messageID: id, contentIndex: payload.contentIndex ?? 0, text: delta) }
            return .assistantTextDelta(delta)
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
            return .other // Handled above to retain the terminal output snapshot.
        case .failed:
            return Self.failure(try ResponsePayload(from: decoder).response)
        case .incomplete:
            return Self.failure(try ResponsePayload(from: decoder).response, incomplete: true)
        case .error:
            let payload = try ErrorPayload(from: decoder)
            let error = try payload.error ?? StreamErrorPayload(from: decoder)
            return .failed(.init(code: .responsesStreamFailed,
                message: error.message ?? "The ChatGPT responses stream failed.",
                http: .init(statusCode: 200, providerCode: error.code, providerType: error.type)), responseID: nil)
        case nil:
            return .other
        }
    }

    private static func failure(_ response: StreamResponsePayload?, incomplete: Bool = false) -> CodexResponsesStreamEvent.Kind {
        let message = incomplete
            ? "The ChatGPT responses stream completed early: \(response?.incompleteDetails?.reason ?? "unknown")."
            : "The ChatGPT responses stream failed."
        return .failed(.init(code: incomplete ? .responsesStreamIncomplete : .responsesStreamFailed,
            message: response?.error?.message ?? message,
            http: .init(statusCode: 200, providerCode: response?.error?.code, providerType: response?.error?.type)),
            responseID: response?.id)
    }

    private struct ErrorPayload: Decodable {
        let error: StreamErrorPayload?
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
        let itemID: String?
        let contentIndex: Int?
        enum CodingKeys: String, CodingKey { case delta; case itemID = "item_id"; case contentIndex = "content_index" }
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

    private struct CompletionPayload: Decodable {
        struct Output: Decodable { let output: [StreamItem]? }
        let response: Output?
    }
}
