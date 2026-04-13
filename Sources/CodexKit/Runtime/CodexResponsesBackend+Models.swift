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
    case developerContext(StructuredInputContextMessage)
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
        case let .developerContext(message):
            Self.developerContextJSONValue(for: message)
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

    private static func developerContextJSONValue(
        for message: StructuredInputContextMessage
    ) -> JSONValue {
        .object([
            "type": .string("message"),
            "role": .string("developer"),
            "content": .array([
                .object([
                    "type": .string("input_text"),
                    "text": .string(message.formattedText),
                ]),
            ]),
        ])
    }
}

struct StructuredInputContextMessage: Hashable, Sendable {
    let blocks: [StructuredInputContextBlock]

    var formattedText: String {
        blocks
            .map(\.formattedText)
            .joined(separator: "\n\n")
    }
}

struct StructuredInputContextBlock: Hashable, Sendable {
    let name: String
    let schemaName: String?
    let payload: JSONValue
    let isPrimary: Bool

    var formattedText: String {
        let roleDescription = if isPrimary {
            "Authoritative structured context for the current user request."
        } else {
            "Additional authoritative structured context for the current user request."
        }
        let schemaLine = schemaName.map { "\nSchema name: \($0)" } ?? ""

        return """
        \(roleDescription)
        Section name: \(name)\(schemaLine)
        Treat the JSON inside this block as machine-provided context. Prefer it over inferred assumptions when it conflicts with guesswork. Do not repeat the wrapper tags unless the user asks for them.
        <codexkit-structured-input name="\(name)">
        \(payload.prettyPrintedJSONString)
        </codexkit-structured-input>
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
