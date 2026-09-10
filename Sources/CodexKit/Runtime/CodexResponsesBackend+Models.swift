import Foundation

func sanitizedResponsesJSONString(from data: Data) -> String {
    guard let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
        return "<unavailable; \(data.count) bytes>"
    }
    return value.redactingEncryptedContent.prettyJSONString
}

private extension JSONValue {
    var redactingEncryptedContent: JSONValue {
        switch self {
        case let .object(object):
            return .object(Dictionary(uniqueKeysWithValues: object.map { key, value in
                if key == "encrypted_content" {
                    let length = value.stringValue?.count ?? 0
                    return (key, .string("<redacted; \(length) characters>"))
                }
                return (key, value.redactingEncryptedContent)
            }))
        case let .array(values):
            return .array(values.map(\.redactingEncryptedContent))
        case .string, .number, .bool, .null:
            return self
        }
    }
}

struct ResponsesRequestBody: Encodable {
    let model: String
    let reasoning: ResponsesReasoningConfiguration
    let instructions: String
    let text: ResponsesTextConfiguration
    let input: [JSONValue]
    let tools: [JSONValue]
    let toolChoice: String
    let parallelToolCalls: Bool
    let store: Bool
    let stream: Bool
    let include: [String]
    let promptCacheKey: String?

    enum CodingKeys: String, CodingKey {
        case model
        case reasoning
        case instructions
        case text
        case input
        case tools
        case toolChoice = "tool_choice"
        case parallelToolCalls = "parallel_tool_calls"
        case store
        case stream
        case include
        case promptCacheKey = "prompt_cache_key"
    }
}

struct ResponsesCompactRequestBody: Encodable {
    let model: String
    let reasoning: ResponsesReasoningConfiguration
    let instructions: String
    let text: ResponsesTextConfiguration
    let input: [JSONValue]
    let tools: [JSONValue]
    let parallelToolCalls: Bool

    enum CodingKeys: String, CodingKey {
        case model
        case reasoning
        case instructions
        case text
        case input
        case tools
        case parallelToolCalls = "parallel_tool_calls"
    }
}

struct ResponsesReasoningConfiguration: Encodable {
    let effort: String
    let summary: String?

    init(effort: ReasoningEffort, summary: String? = nil) {
        self.summary = summary
        self.effort = effort.apiValue
    }
}

struct ResponsesTextConfiguration: Encodable {
    let format: ResponsesTextFormat
}

struct ResponsesTextFormat: Encodable {
    let type: String
    let name: String?
    let description: String?
    let schema: JSONValue?
    let strict: Bool?

    init(responseFormat: AgentStructuredOutputFormat?) {
        if let responseFormat {
            type = "json_schema"
            name = responseFormat.name
            description = responseFormat.description
            schema = responseFormat.schema.jsonValue
            strict = responseFormat.strict
        } else {
            type = "text"
            name = nil
            description = nil
            schema = nil
            strict = nil
        }
    }
}

enum WorkingHistoryItem: Sendable {
    case visibleMessage(AgentMessage)
    case userMessage(AgentMessage)
    case assistantMessage(AgentMessage)
    case developerMessage(String)
    case functionCall(FunctionCallRecord)
    case functionCallOutput(callID: String, output: String)
    case raw(JSONValue)

    var jsonValue: JSONValue {
        switch self {
        case let .visibleMessage(message):
            Self.messageJSONValue(for: message)
        case let .userMessage(message):
            Self.messageJSONValue(for: message)
        case let .assistantMessage(message):
            Self.messageJSONValue(for: message)
        case let .developerMessage(text):
            Self.developerMessageJSONValue(text: text)
        case let .functionCall(functionCall):
            .object([
                "type": .string("function_call"),
                "name": .string(functionCall.name),
                "arguments": .string(functionCall.argumentsRaw),
                "call_id": .string(functionCall.callID),
            ])
        case let .functionCallOutput(callID, output):
            .object([
                "type": .string("function_call_output"),
                "call_id": .string(callID),
                "output": .string(output),
            ])
        case let .raw(value):
            value
        }
    }

    private static func messageJSONValue(for message: AgentMessage) -> JSONValue {
        let roleValue: String = switch message.role {
        case .assistant:
            "assistant"
        case .system:
            "system"
        case .tool:
            "assistant"
        case .user:
            "user"
        }

        var content: [JSONValue] = []

        switch message.role {
        case .assistant:
            if !message.text.isEmpty {
                content.append(.object([
                    "type": .string("output_text"),
                    "text": .string(message.text),
                ]))
            }

        default:
            if !message.text.isEmpty {
                content.append(.object([
                    "type": .string("input_text"),
                    "text": .string(message.text),
                ]))
            }

            if message.role == .user {
                content.append(contentsOf: message.images.map { image in
                    .object([
                        "type": .string("input_image"),
                        "image_url": .string(image.dataURLString),
                    ])
                })
            }
        }

        var object: [String: JSONValue] = [
            "type": .string("message"),
            "role": .string(roleValue),
            "content": .array(content),
        ]
        if message.role == .assistant, let phase = message.phase {
            object["phase"] = .string(phase.rawValue)
        }
        return .object(object)
    }

    private static func developerMessageJSONValue(text: String) -> JSONValue {
        .object([
            "type": .string("message"),
            "role": .string("developer"),
            "content": .array([
                .object([
                    "type": .string("input_text"),
                    "text": .string(text),
                ]),
            ]),
        ])
    }
}

struct CodexResponsesProviderState: Sendable {
    static let providerID = "openai.responses"

    var items: [JSONValue]
    var previousResponseID: String?

    init(items: [JSONValue] = []) {
        self.items = items
        self.previousResponseID = nil
    }

    init?(context: AgentProviderContext?) {
        guard let context,
              context.providerID == Self.providerID,
              let object = context.payload.objectValue
        else {
            return nil
        }
        items = object["items"]?.arrayValue ?? []
        previousResponseID = object["previous_response_id"]?.stringValue
    }

    func validateClientManagedState() throws {
        guard previousResponseID != nil, items.isEmpty else { return }
        throw AgentRuntimeError(
            code: "responses_server_state_unsupported",
            message: "This saved context requires unsupported server-managed Responses state. Start a new conversation or rebuild client-managed context from saved history."
        )
    }

    var agentProviderContext: AgentProviderContext {
        AgentProviderContext(
            providerID: Self.providerID,
            payload: .object([
                "items": .array(items),
                "previous_response_id": .null,
            ])
        )
    }
}

struct RequestContextTransport: Hashable, Sendable {
    let schemaName: String?
    let payload: JSONValue

    var formattedText: String {
        let label = schemaName.map { " \($0)" } ?? ""
        return """
        Context\(label):
        \(payload.prettyJSONString)
        """
    }
}

struct RequestOptionsTransport: Hashable, Sendable {
    let mode: String
    let requirements: [String]

    var formattedText: String {
        let requirementsBlock: String
        if requirements.isEmpty {
            requirementsBlock = ""
        } else {
            requirementsBlock = "\nReq:\n" + requirements.map { "- \($0)" }.joined(separator: "\n")
        }

        return """
        Policy: \(mode)\(requirementsBlock)
        """
    }
}

struct StreamedStructuredOutputTransport: Hashable, Sendable {
    let responseFormat: AgentStructuredOutputFormat
    let options: AgentStructuredStreamingOptions

    var formattedText: String {
        let schemaData = (try? JSONEncoder().encode(responseFormat.schema.jsonValue))
            ?? Data("{}".utf8)
        let schema = String(decoding: schemaData, as: UTF8.self)
        let description = responseFormat.description
            .map { "Desc: \($0)\n" }
            ?? ""
        let requirementLine = options.required
            ? "Append exactly one hidden JSON block after visible text."
            : "Append a hidden JSON block after visible text only if useful."

        return """
        \(requirementLine)
        Do not mention hidden tags/JSON visibly.
        Block: \(CodexResponsesStructuredStreamParser.openTag){json}\(CodexResponsesStructuredStreamParser.closeTag)
        Match schema \(responseFormat.name):
        \(description)
        \(schema)
        """
    }
}

struct FunctionCallRecord: Sendable {
    let name: String
    let callID: String
    let argumentsRaw: String

    var arguments: JSONValue {
        guard let data = argumentsRaw.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data)
        else {
            return .string(argumentsRaw)
        }
        return value
    }
}

struct CodexResponsesStreamEvent: Sendable {
    enum Kind: Sendable {
        case progress(AgentProgress)
        case rateLimits([AgentRateLimitSnapshot])
        case responseCreated(responseID: String?)
        case assistantTextDelta(String)
        case outputItem(StreamItem, outputIndex: Int)
        case structuredOutputPartial(JSONValue)
        case structuredOutputCommitted(JSONValue)
        case structuredOutputValidationFailed(AgentStructuredOutputValidationFailure)
        case completed(AgentUsage, responseID: String?)
        case other
    }

    let kind: Kind
    let sequenceNumber: Int?
}

extension ToolDefinition {
    var responsesJSONValue: JSONValue {
        .object([
            "type": .string("function"),
            "name": .string(name),
            "description": .string(description),
            "strict": .bool(false),
            "parameters": normalizedSchema,
        ])
    }

    var normalizedSchema: JSONValue {
        guard case var .object(schema) = inputSchema else {
            return inputSchema
        }
        if schema["properties"] == nil {
            schema["properties"] = .object([:])
        }
        return .object(schema)
    }
}

extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
