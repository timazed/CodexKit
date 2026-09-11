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
                    code: .responsesEventTooLarge,
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

struct StreamItem: Decodable, Sendable {
    let rawValue: JSONValue
    let kind: StreamItemKind
    let type: ResponsesItemType?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(JSONValue.self)
        let object = rawValue.objectValue ?? [:]
        type = ResponsesItemType(wireValue: object["type"])

        switch type {
        case .message:
            kind = .message(try StreamMessageItem(from: decoder))
        case .functionCall:
            kind = .functionCall(try StreamFunctionCallItem(from: decoder))
        case .imageGenerationCall:
            kind = .imageGenerationCall(try StreamImageGenerationCallItem(from: decoder))
        case .webSearchCall:
            kind = .webSearchCall(try StreamWebSearchCallItem(from: decoder))
        default:
            kind = .other
        }
    }

    var startedProgress: AgentProgress? { progress(completed: false) }
    var completedProgress: AgentProgress? { progress(completed: true) }

    private func progress(completed: Bool) -> AgentProgress? {
        switch kind {
        case let .message(message):
            guard let id = message.id else { return nil }
            return completed ? .messageCompleted(itemID: id, phase: message.phase)
                : .messageStarted(itemID: id, phase: message.phase)
        case let .webSearchCall(search):
            guard let id = search.id else { return nil }
            let status = search.status ?? (completed ? .completed : .inProgress)
            return .webSearch(itemID: id, status: status, action: search.action)
        case .functionCall, .imageGenerationCall, .other:
            return nil
        }
    }
}

enum StreamItemKind: Sendable {
    case message(StreamMessageItem)
    case functionCall(StreamFunctionCallItem)
    case imageGenerationCall(StreamImageGenerationCallItem)
    case webSearchCall(StreamWebSearchCallItem)
    case other
}

struct StreamWebSearchCallItem: Decodable, Sendable {
    let id: String?
    let status: AgentWebSearchStatus?
    let action: JSONValue?
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
        let detail: AgentImageDetail?
        if let value = object["detail"]?.stringValue {
            detail = AgentImageDetail(rawValue: value)
        } else {
            detail = nil
        }
        if let dataURL = object["image_url"]?.stringValue,
           let attachment = AgentImageAttachment(dataURLString: dataURL, detail: detail) {
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
