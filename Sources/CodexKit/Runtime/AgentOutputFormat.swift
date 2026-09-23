import Foundation

/// Limits count source/encoded bytes. Trusted custom decoders also own their allocation discipline.
public struct AgentStructuredOutputLimits: Codable, Hashable, Sendable {
    public var maximumInputBytes = 1_048_576
    public var maximumOutputBytes = 4_194_304
    public var maximumSemanticUnitBytes = 262_144
    public var maximumSemanticUnits = 10_000
    public var maximumNestingDepth = 64
    public var maximumQueuedEventCount = 64
    public var maximumQueuedEventBytes = 1_048_576
    public var maximumSchemaBytes = 262_144

    public init() {}

    func validate() throws {
        guard maximumInputBytes > 0, maximumInputBytes <= AgentStoreLimits.maximumMessageTextByteCount,
            maximumOutputBytes > 0, maximumOutputBytes <= AgentStoreLimits.maximumEmbeddedPayloadByteCount,
            maximumSemanticUnitBytes > 0, maximumSemanticUnitBytes <= maximumQueuedEventBytes,
            maximumSemanticUnits > 0, maximumSemanticUnits <= 10_000,
            maximumNestingDepth > 0, maximumNestingDepth <= 64,
            maximumQueuedEventCount > 0, maximumQueuedEventCount <= 4_096,
            maximumQueuedEventBytes <= 16_777_216, maximumSchemaBytes > 0,
            maximumSchemaBytes <= 1_048_576
        else { throw AgentOutputError.limit("Invalid structured-output limits.") }
    }
}

public enum AgentOutputError: Error, LocalizedError, Sendable {
    case invalidFormat(String)
    case invalidOutput(String)
    case protocolViolation(String)
    case limit(String)
    case unsupportedVersion
    case persistenceUnavailable

    public var errorDescription: String? {
        switch self {
        case let .invalidFormat(message), let .invalidOutput(message), let .protocolViolation(message),
            let .limit(message):
            message
        case .unsupportedVersion: "The stored output format or version does not match this decoder."
        case .persistenceUnavailable: "This output requires an explicit persistence adapter or an ephemeral request."
        }
    }
}

public struct AgentOutputContext: Codable, Hashable, Sendable {
    public let executionID: UUID
    public let threadID: String
    public let turnID: String
    public let messageID: String
    public let documentID: UUID
}

public struct AgentOutputFailure: Sendable {
    public let message: String
    /// Zero-based position when a complete record fails decoding or schema validation.
    public let recordIndex: Int?
    /// The original failure, including typed decoder and delivery errors.
    public let underlyingError: (any Error)?

    public init(message: String, recordIndex: Int? = nil, underlyingError: (any Error)? = nil) {
        self.message = message
        self.recordIndex = recordIndex
        self.underlyingError = underlyingError
    }

    init(error: any Error) {
        self.init(
            message: String(error.localizedDescription.prefix(2_048)),
            recordIndex: (error as? AgentRecordDecodingError)?.recordIndex,
            underlyingError: error
        )
    }
}

public enum AgentOutputEvent<FormatEvent: Sendable, Output: Sendable>: Sendable {
    case lifecycle(AgentEvent)
    case format(AgentOutputContext, FormatEvent)
    case validationFailed(AgentOutputContext?, AgentOutputFailure)
    case outputCommitted(AgentOutputContext, Output)
}

/// An awaited, ordered event sink. `encodedByteCount` must include the whole event payload.
public struct AgentOutputEventSink<Event: Sendable>: Sendable {
    private let emitHandler: @Sendable (Event, Int) async throws -> Void
    init(_ emit: @escaping @Sendable (Event, Int) async throws -> Void) { emitHandler = emit }
    public func emit(_ event: Event, encodedByteCount: Int) async throws {
        try await emitHandler(event, encodedByteCount)
    }
}

/// Each execution creates a fresh decoder. Runtime calls consume/finish sequentially.
/// Implementations must not retain the sink or launch unstructured emission tasks.
public protocol AgentOutputDecoder: Actor {
    associatedtype Event: Sendable
    associatedtype Output: Sendable
    func consume(_ bytes: Data, into sink: AgentOutputEventSink<Event>) async throws
    func finish(into sink: AgentOutputEventSink<Event>) async throws -> Output
    func cancel() async
}

public extension AgentOutputDecoder { func cancel() async {} }

public struct AgentOutputPersistence<Output: Sendable>: Sendable {
    public let encode: @Sendable (Output) throws -> Data
    public let decode: @Sendable (Data) throws -> Output
    public init(
        encode: @escaping @Sendable (Output) throws -> Data,
        decode: @escaping @Sendable (Data) throws -> Output
    ) {
        self.encode = encode
        self.decode = decode
    }
}

public extension AgentOutputPersistence where Output: Codable {
    /// Stable key ordering; the application's Codable implementation still owns value fidelity.
    static var json: Self {
        .init(
            encode: { value in
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                return try encoder.encode(value)
            }, decode: { try JSONDecoder().decode(Output.self, from: $0) })
    }
}

/// Describes generation and creates a decoder. Only AgentRuntime can commit its result.
public protocol AgentOutputFormat: Sendable {
    associatedtype Decoder: AgentOutputDecoder
    /// Provisional events produced by this format's decoder.
    typealias Event = Decoder.Event
    /// The complete value validated and committed by the runtime.
    typealias Output = Decoder.Output
    var name: String { get }
    var codecIdentifier: String { get }
    var formatVersion: Int { get }
    /// Read once before starting a turn. Throw if the format cannot be prepared.
    var formatInstructions: String { get throws }
    var nativeJSONSchema: AgentStructuredOutputFormat? { get }
    /// Stable schema identity used by both generation and saved-output compatibility checks.
    var schemaRepresentation: String? { get throws }
    var limits: AgentStructuredOutputLimits { get }
    var persistence: AgentOutputPersistence<Output>? { get throws }
    func makeDecoder() throws -> Decoder
    func validateFinal(_ output: Output) async throws
}

public extension AgentOutputFormat {
    var formatVersion: Int { 1 }
    var nativeJSONSchema: AgentStructuredOutputFormat? { nil }
    var schemaRepresentation: String? { nil }
    func validateFinal(_ output: Output) async throws {}
}

/// A versioned envelope stored in existing structured-output records by every storage adapter.
/// Encoded typed output preserves integer precision; rawText is the context replay source.
public struct AgentOutputRepresentation: Codable, Hashable, Sendable {
    public let envelopeVersion: Int
    public let codecIdentifier: String
    public let formatVersion: Int
    public let context: AgentOutputContext
    public let schema: String?
    public let rawText: String
    public let encodedOutput: Data

    public func restore<Format: AgentOutputFormat>(using format: Format) throws -> Format.Output {
        try format.limits.validate()
        let schema = try format.schemaRepresentation
        guard envelopeVersion == 1, codecIdentifier == format.codecIdentifier,
            formatVersion == format.formatVersion, self.schema == schema
        else {
            throw AgentOutputError.unsupportedVersion
        }
        guard let persistence = try format.persistence else { throw AgentOutputError.persistenceUnavailable }
        guard encodedOutput.count <= format.limits.maximumOutputBytes,
            rawText.utf8.count <= format.limits.maximumInputBytes
        else { throw AgentOutputError.limit("Stored output exceeds limits.") }
        return try persistence.decode(encodedOutput)
    }
}

public extension AgentStructuredOutputMetadata {
    var outputRepresentation: AgentOutputRepresentation? {
        guard payload.objectValue?["envelopeVersion"] != nil else { return nil }
        return try? JSONDecoder().decode(AgentOutputRepresentation.self, from: JSONEncoder().encode(payload))
    }
}
