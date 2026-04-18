import Foundation

public indirect enum JSONSchema: Hashable, Sendable {
    case string(`enum`: [String] = [])
    case integer
    case number
    case boolean
    case array(items: JSONSchema)
    case object(
        properties: [String: JSONSchema],
        required: [String] = [],
        additionalProperties: Bool = false
    )
    case nullable(JSONSchema)
    case raw(JSONValue)

    public var jsonValue: JSONValue {
        switch self {
        case let .string(values):
            var object: [String: JSONValue] = [
                "type": .string("string"),
            ]
            if !values.isEmpty {
                object["enum"] = .array(values.map(JSONValue.string))
            }
            return .object(object)

        case .integer:
            return .object([
                "type": .string("integer"),
            ])

        case .number:
            return .object([
                "type": .string("number"),
            ])

        case .boolean:
            return .object([
                "type": .string("boolean"),
            ])

        case let .array(items):
            return .object([
                "type": .string("array"),
                "items": items.jsonValue,
            ])

        case let .object(properties, required, additionalProperties):
            var object: [String: JSONValue] = [
                "type": .string("object"),
                "properties": .object(properties.mapValues(\.jsonValue)),
                "additionalProperties": .bool(additionalProperties),
            ]
            if !required.isEmpty {
                object["required"] = .array(required.map(JSONValue.string))
            }
            return .object(object)

        case let .nullable(schema):
            return .object([
                "anyOf": .array([
                    schema.jsonValue,
                    .object(["type": .string("null")]),
                ]),
            ])

        case let .raw(value):
            return value
        }
    }
}

extension JSONSchema: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(JSONValue.self)
        self = .raw(value)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(jsonValue)
    }
}

public struct AgentStructuredOutputFormat: Codable, Hashable, Sendable {
    public let name: String
    public let description: String?
    public let schema: JSONSchema
    public let strict: Bool

    public init(
        name: String,
        description: String? = nil,
        schema: JSONSchema,
        strict: Bool = true
    ) {
        self.name = name
        self.description = description
        self.schema = schema
        self.strict = strict
    }

    public init(
        name: String,
        description: String? = nil,
        rawSchema: JSONValue,
        strict: Bool = true
    ) {
        self.init(
            name: name,
            description: description,
            schema: .raw(rawSchema),
            strict: strict
        )
    }
}

public protocol AgentStructuredOutput: Decodable, Sendable {
    static var responseFormat: AgentStructuredOutputFormat { get }
}

struct AgentResponseContract: Sendable {
    enum DeliveryMode: Sendable {
        case oneShot
        case streaming(options: AgentStructuredStreamingOptions)
    }

    let format: AgentStructuredOutputFormat
    let deliveryMode: DeliveryMode

    var textFormat: AgentStructuredOutputFormat? {
        switch deliveryMode {
        case .oneShot:
            return format
        case .streaming:
            return nil
        }
    }

    var streamedRequest: AgentStreamedStructuredOutputRequest? {
        switch deliveryMode {
        case .oneShot:
            return nil
        case let .streaming(options):
            return AgentStreamedStructuredOutputRequest(
                responseFormat: format,
                options: options
            )
        }
    }
}

public struct AgentImportedContent: Codable, Hashable, Sendable {
    public var textSnippets: [String]
    public var urls: [URL]
    public var images: [AgentImageAttachment]

    public init(
        textSnippets: [String] = [],
        urls: [URL] = [],
        images: [AgentImageAttachment] = []
    ) {
        self.textSnippets = textSnippets
        self.urls = urls
        self.images = images
    }

    public var hasContent: Bool {
        let hasText = textSnippets.contains {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return hasText || !urls.isEmpty || !images.isEmpty
    }

    public func composedText(prompt: String? = nil) -> String {
        var sections: [String] = []

        if let prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append(prompt.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let normalizedSnippets = textSnippets
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        sections.append(contentsOf: normalizedSnippets)

        if !urls.isEmpty {
            sections.append(
                """
                Shared URLs:
                \(urls.map(\.absoluteString).joined(separator: "\n"))
                """
            )
        }

        return sections.joined(separator: "\n\n")
    }
}
