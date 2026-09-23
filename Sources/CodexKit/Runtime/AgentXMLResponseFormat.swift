import Foundation

public struct AgentXMLResponseFormat: AgentOutputFormat {
    public let name: String
    public let description: String?
    public let schema: XMLSchema
    public var limits: AgentStructuredOutputLimits
    public var streaming: AgentXMLStreamingOptions
    public var finalValidation: @Sendable (AgentXMLDocument) async throws -> Void

    public init(name: String, description: String? = nil, schema: XMLSchema,
                limits: AgentStructuredOutputLimits = .init(), streaming: AgentXMLStreamingOptions = .init(),
                finalValidation: @escaping @Sendable (AgentXMLDocument) async throws -> Void = { _ in }) {
        self.name = name; self.description = description; self.schema = schema
        self.limits = limits; self.streaming = streaming; self.finalValidation = finalValidation
    }
    public var codecIdentifier: String { "codexkit.xml/v1" }
    public var schemaRepresentation: String? {
        guard let source = try? schema.xsd() else { return nil }
        return JSONValue.object(["xsd": .string(source), "root": .string(schema.rootName.expandedName)]).prettyPrintedJSONString
    }
    public var formatInstructions: String {
        """
        Finish tool work before the final answer. Return exactly one complete XML 1.0 UTF-8 document.
        Root: \(schema.rootName.expandedName). Format: \(name). \(description ?? "")
        No prose or code fences outside XML. No DTDs or custom entities. Escape & and < in text, and quotes in attributes.
        Prefer escaped text to CDATA for progressive prose. Do not restart or revise emitted elements.
        The final document must validate against this authoritative self-contained XSD:
        \((try? schema.xsd()) ?? "INVALID SCHEMA")
        """
    }
    public var persistence: AgentOutputPersistence<AgentXMLDocument>? {
        let schema = schema, limits = limits, options = streaming
        return .init(encode: { Data($0.rawXML.utf8) }, decode: { bytes in
            let validator = try AgentXMLSchemaValidator(xsd: schema.xsd(), root: schema.rootName, limits: limits)
            let parser = try AgentXMLParserEngine(limits: limits,
                options: .init(completedElements: .none, emitTextDeltas: false, identityAttribute: options.identityAttribute))
            for offset in stride(from: 0, to: bytes.count, by: 64) {
                _ = try parser.feed(Data(bytes[offset ..< min(offset + 64, bytes.count)]))
            }
            _ = try parser.feed(Data(), final: true)
            guard let root = parser.root, String(data: bytes, encoding: .utf8) != nil else { throw AgentOutputError.invalidOutput("Invalid stored XML.") }
            try validator.validate(bytes, root: root)
            return .init(rawXML: String(decoding: bytes, as: UTF8.self), root: root)
        })
    }
    public func makeDecoder() throws -> AgentXMLOutputDecoder {
        try limits.validate()
        let validator = try AgentXMLSchemaValidator(xsd: schema.xsd(), root: schema.rootName, limits: limits)
        return try .init(validator: validator, limits: limits, options: streaming)
    }
    public func validateFinal(_ output: AgentXMLDocument) async throws { try await finalValidation(output) }
}

public actor AgentXMLOutputDecoder: AgentOutputDecoder {
    public typealias Event = AgentXMLOutputEvent
    public typealias Output = AgentXMLDocument
    private var engine: AgentXMLParserEngine?
    private let validator: AgentXMLSchemaValidator
    private let limits: AgentStructuredOutputLimits
    private var source = Data()

    init(validator: AgentXMLSchemaValidator, limits: AgentStructuredOutputLimits, options: AgentXMLStreamingOptions) throws {
        self.validator = validator; self.limits = limits
        engine = try .init(limits: limits, options: options)
    }
    public func consume(_ bytes: Data, into sink: AgentOutputEventSink<Event>) async throws {
        guard let engine else { throw AgentOutputError.protocolViolation("XML decoder has finished.") }
        guard bytes.count <= limits.maximumInputBytes - source.count else { throw AgentOutputError.limit("XML input exceeds byte limit.") }
        source.append(bytes)
        for offset in stride(from: 0, to: bytes.count, by: 64) {
            try Task.checkCancellation()
            let events = try engine.feed(Data(bytes[offset ..< min(offset + 64, bytes.count)]))
            for (event, size) in events { try await sink.emit(event, encodedByteCount: size) }
        }
    }
    public func finish(into sink: AgentOutputEventSink<Event>) async throws -> Output {
        guard let engine else { throw AgentOutputError.protocolViolation("XML decoder has finished.") }
        self.engine = nil
        for (event, size) in try engine.feed(Data(), final: true) { try await sink.emit(event, encodedByteCount: size) }
        guard let root = engine.root, String(data: source, encoding: .utf8) != nil else {
            throw AgentOutputError.invalidOutput("XML requires one complete UTF-8 document.")
        }
        try Task.checkCancellation()
        try validator.validate(source, root: root)
        try Task.checkCancellation()
        return .init(rawXML: String(decoding: source, as: UTF8.self), root: root)
    }
    public func cancel() { engine = nil; source.removeAll() }
}
