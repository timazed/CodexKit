import Foundation

struct SSEEventPayload {
    let event: String?
    let data: String
}

struct SSEEventParser {
    private var eventName: String?
    private var dataLines: [String] = []

    mutating func consume(line: String) -> SSEEventPayload? {
        if line.isEmpty {
            return flush()
        }

        if line.hasPrefix("event:") {
            eventName = Self.trimmedFieldValue(from: line)
        } else if line.hasPrefix("data:") {
            dataLines.append(Self.trimmedFieldValue(from: line))
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
}

enum StreamItem: Decodable {
    case message(StreamMessageItem)
    case functionCall(StreamFunctionCallItem)
    case other

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let object = try container.decode([String: JSONValue].self)
        let type = object["type"]?.stringValue

        switch type {
        case "message":
            let data = try JSONEncoder().encode(object)
            self = .message(try JSONDecoder().decode(StreamMessageItem.self, from: data))
        case "function_call":
            let data = try JSONEncoder().encode(object)
            self = .functionCall(try JSONDecoder().decode(StreamFunctionCallItem.self, from: data))
        default:
            self = .other
        }
    }
}

struct StreamMessageItem: Decodable {
    let role: String
    let content: [StreamMessageContent]
}

struct StreamMessageContent: Decodable {
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

    private static func parseImageAttachment(from object: [String: JSONValue]) -> AgentImageAttachment? {
        if let dataURL = object["image_url"]?.stringValue,
           let attachment = AgentImageAttachment(dataURLString: dataURL) {
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

struct StreamFunctionCallItem: Decodable {
    let name: String
    let arguments: String
    let callID: String

    enum CodingKeys: String, CodingKey {
        case name
        case arguments
        case callID = "call_id"
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
}

struct StreamIncompleteDetails: Decodable {
    let reason: String?
}
