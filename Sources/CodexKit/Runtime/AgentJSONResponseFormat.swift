import Foundation

/// Native provider JSON Schema with provisional raw text, never partial typed values.
public struct AgentJSONResponseFormat<Output: Codable & Sendable>: AgentOutputFormat {
    public let responseFormat: AgentStructuredOutputFormat
    public var limits: AgentStructuredOutputLimits
    public var finalValidation: @Sendable (Output) async throws -> Void

    public init(
        name: String, description: String? = nil, schema: JSONSchema,
        limits: AgentStructuredOutputLimits = .init(),
        finalValidation: @escaping @Sendable (Output) async throws -> Void = { _ in }
    ) {
        self.responseFormat = .init(name: name, description: description, schema: schema)
        self.limits = limits
        self.finalValidation = finalValidation
    }

    public var name: String { responseFormat.name }
    public var codecIdentifier: String { "codexkit.json/v1" }
    public var nativeJSONSchema: AgentStructuredOutputFormat? { responseFormat }
    public var schemaRepresentation: String? { responseFormat.schema.jsonValue.prettyPrintedJSONString }
    public var formatInstructions: String {
        "Finish tool work before emitting the final JSON answer. Do not restart or revise the answer after it begins."
    }
    public var persistence: AgentOutputPersistence<Output>? { .json }
    public func makeDecoder() throws -> AgentJSONOutputDecoder<Output> {
        try limits.validate()
        try AgentJSONSchemaValidator.validateSchema(responseFormat.schema)
        return .init(schema: responseFormat.schema, limits: limits)
    }
    public func validateFinal(_ output: Output) async throws { try await finalValidation(output) }
}

public extension AgentJSONResponseFormat where Output: AgentStructuredOutput {
    /// Reuses the existing typed response's schema, description, and strictness.
    init(
        _ output: Output.Type,
        limits: AgentStructuredOutputLimits = .init(),
        finalValidation: @escaping @Sendable (Output) async throws -> Void = { _ in }
    ) {
        responseFormat = Output.responseFormat
        self.limits = limits
        self.finalValidation = finalValidation
    }
}

public enum AgentJSONOutputEvent: Sendable { case rawJSONDelta(String) }

public actor AgentJSONOutputDecoder<Output: Codable & Sendable>: AgentOutputDecoder {
    public typealias Event = AgentJSONOutputEvent
    private let schema: JSONSchema
    private let limits: AgentStructuredOutputLimits
    private var source = Data()
    private var text = AgentOutputUTF8Buffer()
    private var ended = false

    init(schema: JSONSchema, limits: AgentStructuredOutputLimits) {
        self.schema = schema
        self.limits = limits
    }

    public func consume(_ bytes: Data, into sink: AgentOutputEventSink<Event>) async throws {
        guard !ended else { throw AgentOutputError.protocolViolation("JSON decoder has finished.") }
        guard bytes.count <= limits.maximumInputBytes - source.count else {
            throw AgentOutputError.limit("JSON input exceeds limit.")
        }
        source.append(bytes)
        var buffer = text
        try await buffer.consume(bytes, maximumChunk: limits.maximumSemanticUnitBytes) { text in
            try await sink.emit(.rawJSONDelta(text), encodedByteCount: text.utf8.count)
        }
        if !ended { text = buffer }
    }

    public func finish(into sink: AgentOutputEventSink<Event>) throws -> Output {
        guard !ended else { throw AgentOutputError.protocolViolation("JSON decoder has finished.") }
        ended = true
        try text.finish()
        try AgentStrictJSON.validate(source, maximumDepth: limits.maximumNestingDepth)
        try AgentJSONSchemaValidator.validate(JSONDecoder().decode(JSONValue.self, from: source), schema: schema)
        // Decode original bytes: JSONValue's Double storage must not round large integers.
        return try JSONDecoder().decode(Output.self, from: source)
    }
    public func cancel() {
        ended = true
        source.removeAll()
        text = .init()
    }
}

/// Separates UTF-8 byte boundaries from semantic framing for text-based codecs.
struct AgentOutputUTF8Buffer: Sendable {
    private var pending = Data()
    mutating func consume(
        _ bytes: Data, maximumChunk: Int,
        emit: @Sendable (String) async throws -> Void
    ) async throws {
        guard maximumChunk >= 4 else {
            throw AgentOutputError.invalidFormat("Text events require a byte limit of at least four.")
        }
        var offset = 0
        while offset < bytes.count {
            try Task.checkCancellation()
            let count = min(maximumChunk - pending.count, bytes.count - offset)
            pending.append(contentsOf: bytes[offset..<offset + count])
            offset += count
            var decoded: (String, Int)?
            for suffix in 0...min(3, pending.count) {
                let prefix = pending.prefix(pending.count - suffix)
                if String(data: prefix, encoding: .utf8) != nil {
                    decoded = (String(decoding: prefix, as: UTF8.self), pending.count - suffix)
                    break
                }
            }
            guard let (text, length) = decoded else {
                throw AgentOutputError.invalidOutput("Output is not valid UTF-8.")
            }
            if length > 0 {
                pending = Data(pending.dropFirst(length))
                try await emit(text)
            }
        }
    }
    func finish() throws {
        guard pending.isEmpty else { throw AgentOutputError.invalidOutput("Incomplete UTF-8 at end of output.") }
    }
}
