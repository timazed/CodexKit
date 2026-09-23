import Foundation

public enum AgentRecordCodec: String, Codable, Hashable, Sendable {
    case jsonLines = "jsonlines/v1"
}

public struct AgentRecordCollection<Record: Codable & Sendable>: Codable, Sendable {
    public let records: [Record]
    public init(records: [Record]) { self.records = records }
}

public enum AgentRecordEvent<Record: Sendable>: Sendable {
    case recordCompleted(index: Int, record: Record)
}

/// A malformed record, retaining its zero-based index and original decoding error.
public struct AgentRecordDecodingError: Error, LocalizedError, Sendable {
    public let recordIndex: Int
    public let underlyingError: any Error

    public var errorDescription: String? {
        "Record \(recordIndex): \(underlyingError.localizedDescription)"
    }
}

public struct AgentRecordResponseFormat<Record: Codable & Sendable>: AgentOutputFormat {
    public let name: String
    public let schema: JSONSchema?
    public let codec: AgentRecordCodec
    public var limits: AgentStructuredOutputLimits
    public var minimumRecords: Int
    public var maximumRecords: Int
    public var finalValidation: @Sendable (AgentRecordCollection<Record>) async throws -> Void

    public init(
        name: String, record: Record.Type = Record.self, schema: JSONSchema? = nil,
        codec: AgentRecordCodec = .jsonLines,
        limits: AgentStructuredOutputLimits = .init(), minimumRecords: Int = 0,
        maximumRecords: Int = 10_000,
        finalValidation: @escaping @Sendable (AgentRecordCollection<Record>) async throws -> Void = { _ in }
    ) {
        self.name = name
        self.schema = schema
        self.codec = codec
        self.limits = limits
        self.minimumRecords = minimumRecords
        self.maximumRecords = maximumRecords
        self.finalValidation = finalValidation
    }

    public var codecIdentifier: String { "codexkit." + codec.rawValue }
    public var schemaRepresentation: String? { schema?.jsonValue.prettyPrintedJSONString }
    public var formatInstructions: String {
        """
        Finish tool work before the final answer. Return one complete JSON record per physical line.
        Never pretty-print, use blank lines, duplicate keys, code fences, or prose outside records.
        Escape newlines inside strings. Do not restart or revise completed records.
        Return between \(minimumRecords) and \(maximumRecords) records for \(name).
        \(schemaRepresentation.map { "Each record must match this JSON Schema: " + $0 } ?? "")
        """
    }
    public var persistence: AgentOutputPersistence<AgentRecordCollection<Record>>? { .json }
    public func makeDecoder() throws -> AgentJSONLinesDecoder<Record> {
        try limits.validate()
        guard minimumRecords >= 0, maximumRecords >= minimumRecords,
            maximumRecords <= limits.maximumSemanticUnits
        else { throw AgentOutputError.invalidFormat("Invalid record count bounds.") }
        if let schema { try AgentJSONSchemaValidator.validateSchema(schema) }
        return AgentJSONLinesDecoder(schema: schema, limits: limits, minimum: minimumRecords, maximum: maximumRecords)
    }
    public func validateFinal(_ output: AgentRecordCollection<Record>) async throws {
        try await finalValidation(output)
    }
}

public actor AgentJSONLinesDecoder<Record: Codable & Sendable>: AgentOutputDecoder {
    public typealias Event = AgentRecordEvent<Record>
    public typealias Output = AgentRecordCollection<Record>
    private let schema: JSONSchema?
    private let limits: AgentStructuredOutputLimits
    private let minimum: Int
    private let maximum: Int
    private var line = Data()
    private var records: [Record] = []
    private var inputBytes = 0
    private var outputBytes = 16
    private var ended = false

    init(schema: JSONSchema?, limits: AgentStructuredOutputLimits, minimum: Int, maximum: Int) {
        self.schema = schema
        self.limits = limits
        self.minimum = minimum
        self.maximum = maximum
    }

    public func consume(_ bytes: Data, into sink: AgentOutputEventSink<Event>) async throws {
        guard !ended else { throw AgentOutputError.protocolViolation("The record decoder has finished.") }
        guard bytes.count <= limits.maximumInputBytes - inputBytes else {
            throw AgentOutputError.limit("Record stream exceeds input limit.")
        }
        inputBytes += bytes.count
        for byte in bytes {
            try Task.checkCancellation()
            if byte == 10 {
                try await completeLine(into: sink)
            } else {
                guard line.count < limits.maximumSemanticUnitBytes else {
                    throw AgentOutputError.limit("Record exceeds byte limit.")
                }
                line.append(byte)
            }
        }
    }

    private func completeLine(into sink: AgentOutputEventSink<Event>) async throws {
        guard records.count < maximum else { throw AgentOutputError.limit("Record count exceeded.") }
        let index = records.count
        let data = line
        line.removeAll(keepingCapacity: true)
        let record: Record
        do {
            try AgentStrictJSON.validate(data, maximumDepth: limits.maximumNestingDepth)
            if let schema {
                let value = try JSONDecoder().decode(JSONValue.self, from: data)
                try AgentJSONSchemaValidator.validate(value, schema: schema)
            }
            record = try JSONDecoder().decode(Record.self, from: data)
        } catch is CancellationError {
            throw CancellationError()
        } catch AgentOutputError.limit(let message) {
            throw AgentOutputError.limit(message)
        } catch {
            throw AgentRecordDecodingError(recordIndex: index, underlyingError: error)
        }

        let encodedCount = try JSONEncoder().encode(record).count
        guard encodedCount <= limits.maximumSemanticUnitBytes,
            encodedCount + 1 <= limits.maximumOutputBytes - outputBytes
        else {
            throw AgentOutputError.limit("Decoded records exceed their byte limit.")
        }
        outputBytes += encodedCount + 1
        records.append(record)
        // Delivery failures are not malformed records. Preserve their original type.
        try await sink.emit(.recordCompleted(index: index, record: record), encodedByteCount: encodedCount)
    }

    public func finish(into sink: AgentOutputEventSink<Event>) async throws -> Output {
        guard !ended else { throw AgentOutputError.protocolViolation("The record decoder has finished.") }
        if !line.isEmpty { try await completeLine(into: sink) }
        ended = true
        guard records.count >= minimum else { throw AgentOutputError.invalidOutput("Too few records.") }
        return .init(records: records)
    }
    public func cancel() {
        ended = true
        line.removeAll()
        records.removeAll()
    }
}
