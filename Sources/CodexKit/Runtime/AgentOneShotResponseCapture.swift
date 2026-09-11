import Foundation

struct AgentOneShotResponseValidation: Sendable {
    let format: AgentStructuredOutputFormat
    let validate: @Sendable (AgentMessage) async throws -> Void
}

/// Decodes before the runtime commits the reply and retains the exact decoded
/// value for the caller, including custom decoder behavior and integer precision.
actor AgentOneShotResponseCapture<Output: Decodable & Sendable> {
    private let format: AgentStructuredOutputFormat
    private let decoder: JSONDecoder
    private var output: Output?

    init(format: AgentStructuredOutputFormat, decoder: JSONDecoder) {
        self.format = format
        self.decoder = decoder
    }

    func validate(_ message: AgentMessage) throws {
        guard message.text.utf8.count <= AgentStoreLimits.maximumEmbeddedPayloadByteCount else {
            throw AgentRuntimeError(code: .structuredOutputValidationLimit,
                message: "Structured output exceeds the supported payload size.")
        }
        let data = Data(message.text.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        let value: JSONValue
        do { value = try JSONDecoder().decode(JSONValue.self, from: data) }
        catch { throw decodingError(error) }
        try AgentJSONSchemaValidator.validate(value, schema: format.schema)
        do { output = try decoder.decode(Output.self, from: data) }
        catch { throw decodingError(error) }
    }

    func value() throws -> Output {
        guard let output else { throw AgentRuntimeError.structuredOutputMissing(formatName: format.name) }
        return output
    }

    private func decodingError(_ error: Error) -> AgentRuntimeError {
        .structuredOutputDecodingFailed(typeName: String(describing: Output.self), underlyingMessage: error.localizedDescription)
    }
}
