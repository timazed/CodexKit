import Foundation

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

    init(effort: ReasoningEffort) {
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
            content.append(contentsOf: message.images.map { image in
                .object([
                    "type": .string("output_image"),
                    "image_url": .string(image.dataURLString),
                ])
            })

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

        return .object([
            "type": .string("message"),
            "role": .string(roleValue),
            "content": .array(content),
        ])
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

struct RequestContextTransport: Hashable, Sendable {
    let name: String
    let schemaName: String?
    let payload: JSONValue

    var formattedText: String {
        let schemaLine = schemaName.map { "\nSchema name: \($0)" } ?? ""
        return """
        CodexKit request context:
        Section name: \(name)\(schemaLine)
        Treat the JSON below as authoritative host-app context for the current turn. Prefer it over inferred assumptions when they conflict.
        <codexkit-context name="\(name)">
        \(payload.prettyPrintedJSONString)
        </codexkit-context>
        """
    }
}

struct RequestOptionsTransport: Hashable, Sendable {
    let name: String
    let schemaName: String?
    let mode: String
    let requirements: [String]

    var formattedText: String {
        let schemaLine = schemaName.map { "\nSchema name: \($0)" } ?? ""
        let requirementsBlock: String
        if requirements.isEmpty {
            requirementsBlock = ""
        } else {
            requirementsBlock = "\nRequirements:\n" + requirements.map { "- \($0)" }.joined(separator: "\n")
        }

        return """
        CodexKit request options:
        Section name: \(name)\(schemaLine)
        Treat the following as the fulfillment policy for this turn.
        Mode:
        - \(mode)\(requirementsBlock)
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
            .map { "Description: \($0)\n" }
            ?? ""
        let requirementLine = options.required
            ? "You must emit exactly one hidden structured output block."
            : "Emit the hidden structured output block only when it is useful and you can satisfy the schema."

        return """
        CodexKit streamed response contract:
        - Respond with normal user-facing assistant text first.
        - Do not mention any hidden framing or transport markers in the visible text.
        - After the visible text, optionally append one hidden structured output block using the exact tags below.
        - Hidden block opening tag: \(CodexResponsesStructuredStreamParser.openTag)
        - Hidden block closing tag: \(CodexResponsesStructuredStreamParser.closeTag)
        - The hidden block contents must be valid JSON matching the declared schema.
        - \(requirementLine)
        \(description)Schema name: \(responseFormat.name)
        Schema JSON:
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

enum CodexResponsesStreamEvent: Sendable {
    case assistantTextDelta(String)
    case assistantMessage(AgentMessage)
    case structuredOutputPartial(JSONValue)
    case structuredOutputCommitted(JSONValue)
    case structuredOutputValidationFailed(AgentStructuredOutputValidationFailure)
    case functionCall(FunctionCallRecord)
    case completed(AgentUsage)
}

struct PendingToolResults: Sendable {
    private actor Storage {
        private var waiting: [String: CheckedContinuation<ToolResultEnvelope, Error>] = [:]
        private var resolved: [String: ToolResultEnvelope] = [:]

        func wait(for invocationID: String) async throws -> ToolResultEnvelope {
            if let resolved = resolved.removeValue(forKey: invocationID) {
                return resolved
            }

            return try await withCheckedThrowingContinuation { continuation in
                waiting[invocationID] = continuation
            }
        }

        func resolve(_ result: ToolResultEnvelope, for invocationID: String) {
            if let continuation = waiting.removeValue(forKey: invocationID) {
                continuation.resume(returning: result)
            } else {
                resolved[invocationID] = result
            }
        }
    }

    private let storage = Storage()

    func wait(for invocationID: String) async throws -> ToolResultEnvelope {
        try await storage.wait(for: invocationID)
    }

    func resolve(_ result: ToolResultEnvelope, for invocationID: String) async {
        await storage.resolve(result, for: invocationID)
    }
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
