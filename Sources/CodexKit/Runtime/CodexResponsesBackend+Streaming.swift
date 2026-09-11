import Foundation

struct SSEEventPayload {
    let event: String?
    let data: String
}

struct SSEEventParser {
    private var eventName: String?
    private var dataLines: [String] = []
    private var dataByteCount = 0

    mutating func consume(line: String) throws -> SSEEventPayload? {
        if line.isEmpty {
            return flush()
        }

        if line.hasPrefix("event:") {
            eventName = Self.trimmedFieldValue(from: line)
        } else if line.hasPrefix("data:") {
            let value = Self.trimmedFieldValue(from: line)
            let separatorBytes = dataLines.isEmpty ? 0 : 1
            let (nextCount, overflow) = dataByteCount.addingReportingOverflow(
                value.utf8.count + separatorBytes
            )
            guard !overflow,
                  nextCount <= AgentStoreLimits.maximumResponseEventByteCount else {
                throw AgentRuntimeError(
                    code: "responses_event_too_large",
                    message: "A Responses stream event exceeded the supported size limit."
                )
            }
            dataByteCount = nextCount
            dataLines.append(value)
        }

        return nil
    }

    mutating func finish() -> SSEEventPayload? {
        flush()
    }

    private mutating func flush() -> SSEEventPayload? {
        guard !dataLines.isEmpty else {
            eventName = nil
            return nil
        }

        let payload = SSEEventPayload(
            event: eventName,
            data: dataLines.joined(separator: "\n")
        )
        eventName = nil
        dataLines.removeAll(keepingCapacity: true)
        dataByteCount = 0
        return payload
    }

    private static func trimmedFieldValue(from line: String) -> String {
        let value = line.drop { $0 != ":" }
        return value.dropFirst().trimmingCharacters(in: .whitespaces)
    }
}

struct StreamEnvelope: Decodable {
    let type: String
    let delta: String?
    let item: StreamItem?
    let response: StreamResponsePayload?
    let outputIndex: Int?
    let sequenceNumber: Int?
    let itemID: String?
    let summaryIndex: Int?

    enum CodingKeys: String, CodingKey {
        case type
        case delta
        case item
        case response
        case outputIndex = "output_index"
        case sequenceNumber = "sequence_number"
        case itemID = "item_id"
        case summaryIndex = "summary_index"
    }
}

struct StreamItem: Decodable, Sendable {
    let rawValue: JSONValue
    let kind: StreamItemKind

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(JSONValue.self)
        let object = rawValue.objectValue ?? [:]
        let type = object["type"]?.stringValue

        switch type {
        case "message":
            let data = try JSONEncoder().encode(object)
            kind = .message(try JSONDecoder().decode(StreamMessageItem.self, from: data))
        case "function_call":
            let data = try JSONEncoder().encode(object)
            kind = .functionCall(try JSONDecoder().decode(StreamFunctionCallItem.self, from: data))
        case "image_generation_call":
            let data = try JSONEncoder().encode(object)
            kind = .imageGenerationCall(try JSONDecoder().decode(StreamImageGenerationCallItem.self, from: data))
        default:
            kind = .other
        }
    }
}

enum StreamItemKind: Sendable {
    case message(StreamMessageItem)
    case functionCall(StreamFunctionCallItem)
    case imageGenerationCall(StreamImageGenerationCallItem)
    case other
}

struct StreamMessageItem: Decodable, Sendable {
    let id: String?
    let role: String
    let phase: AgentMessagePhase?
    let content: [StreamMessageContent]
}

struct StreamMessageContent: Decodable, Sendable {
    let type: String
    let displayText: String?
    let imageAttachment: AgentImageAttachment?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let object = try container.decode([String: JSONValue].self)
        type = object["type"]?.stringValue ?? ""
        displayText = object["text"]?.stringValue ?? object["refusal"]?.stringValue
        imageAttachment = Self.parseImageAttachment(from: object)
    }

    static func parseImageAttachment(from object: [String: JSONValue]) -> AgentImageAttachment? {
        if let dataURL = object["image_url"]?.stringValue,
           let attachment = AgentImageAttachment(dataURLString: dataURL,
                detail: object["detail"]?.stringValue.flatMap(AgentImageDetail.init(rawValue:))) {
            return attachment
        }

        if let imageObject = object["image"]?.objectValue,
           let dataURL = imageObject["image_url"]?.stringValue,
           let attachment = AgentImageAttachment(dataURLString: dataURL) {
            return attachment
        }

        if let b64 = object["b64_json"]?.stringValue {
            return AgentImageAttachment(base64String: b64)
        }

        return nil
    }
}

struct StreamFunctionCallItem: Decodable, Sendable {
    let name: String
    let arguments: String
    let callID: String

    enum CodingKeys: String, CodingKey {
        case name
        case arguments
        case callID = "call_id"
    }
}

struct StreamImageGenerationCallItem: Decodable, Sendable {
    let id: String
    let status: String
    let action: String?
    let background: String?
    let outputFormat: String?
    let quality: String?
    let size: String?
    let revisedPrompt: String?
    let result: String?

    enum CodingKeys: String, CodingKey {
        case id
        case status
        case action
        case background
        case outputFormat = "output_format"
        case quality
        case size
        case revisedPrompt = "revised_prompt"
        case result
    }

    var imageAttachment: AgentImageAttachment? {
        guard let result else {
            return nil
        }
        return AgentImageAttachment(
            base64String: result,
            id: id,
            generationMetadata: AgentImageGenerationMetadata(
                id: id,
                status: status,
                action: action,
                revisedPrompt: revisedPrompt,
                background: background,
                outputFormat: outputFormat,
                quality: quality,
                size: size
            )
        )
    }

    var assistantText: String {
        revisedPrompt ?? ""
    }
}

struct StreamResponsePayload: Decodable {
    let id: String?
    let usage: StreamUsage?
    let error: StreamErrorPayload?
    let incompleteDetails: StreamIncompleteDetails?

    enum CodingKeys: String, CodingKey {
        case id
        case usage
        case error
        case incompleteDetails = "incomplete_details"
    }
}

struct StreamUsage: Decodable {
    let inputTokens: Int
    let inputTokensDetails: StreamInputTokenDetails?
    let outputTokens: Int

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case inputTokensDetails = "input_tokens_details"
        case outputTokens = "output_tokens"
    }

    var assistantUsage: AgentUsage {
        AgentUsage(
            inputTokens: inputTokens,
            cachedInputTokens: inputTokensDetails?.cachedTokens ?? 0,
            outputTokens: outputTokens
        )
    }
}

struct StreamInputTokenDetails: Decodable {
    let cachedTokens: Int

    enum CodingKeys: String, CodingKey {
        case cachedTokens = "cached_tokens"
    }
}

struct StreamErrorPayload: Decodable {
    let message: String?
    let code: String?
    let type: String?
}

struct StreamIncompleteDetails: Decodable {
    let reason: String?
}
