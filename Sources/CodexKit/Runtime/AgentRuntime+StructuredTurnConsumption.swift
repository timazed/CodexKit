import Foundation

extension AgentRuntime {
    /// Structured payload handling is layered onto the shared turn lifecycle.
    /// Decode/validate before touching durable state or publishing a commit.
    func consumeStructuredOutput<Output: Decodable & Sendable>(
        _ event: AgentBackendEvent,
        in threadID: String,
        turnID: String,
        configuration: AgentStructuredTurnConfiguration<Output>,
        storesTurnState: Bool,
        sink: AgentTurnEventSink<Output>
    ) async throws -> Bool {
        let value: JSONValue
        let isPartial: Bool
        switch event {
        case let .structuredOutputPartial(payload): value = payload; isPartial = true
        case let .structuredOutputCommitted(payload): value = payload; isPartial = false
        case let .structuredOutputValidationFailed(failure):
            if storesTurnState {
                try setLatestPartialStructuredOutput(nil, for: threadID)
                try await persistState()
            }
            try await sink.validationFailed(failure)
            if failure.stage == .committed {
                throw AgentRuntimeError.structuredOutputInvalid(stage: .committed, underlyingMessage: failure.message)
            }
            return false
        default: return false
        }

        let decoded: Output
        do {
            try AgentJSONSchemaValidator.validate(value, schema: configuration.format.schema, partial: isPartial)
            decoded = try decodeStructuredValue(value, as: Output.self, decoder: configuration.decoder)
        } catch {
            let stage: AgentStructuredOutputValidationStage = isPartial ? .partial : .committed
            try await sink.validationFailed(.init(stage: stage, message: error.localizedDescription, rawPayload: value.prettyJSONString))
            if isPartial { return false }
            throw AgentRuntimeError.structuredOutputInvalid(stage: stage, underlyingMessage: error.localizedDescription)
        }

        if isPartial {
            if storesTurnState {
                try setLatestPartialStructuredOutput(.init(turnID: turnID, formatName: configuration.format.name,
                    payload: value, updatedAt: Date()), for: threadID)
                updateThreadTimestamp(Date(), for: threadID)
                try await persistState()
            }
            if configuration.options.emitPartials { try await sink.partial(decoded) }
            return false
        }

        let duplicate = storesTurnState ? try await hasStoredStructuredOutput(turnID: turnID,
            formatName: configuration.format.name, in: threadID) : false
        if storesTurnState, !duplicate {
            let metadata = AgentStructuredOutputMetadata(formatName: configuration.format.name, payload: value)
            try setLatestStructuredOutputMetadata(metadata, for: threadID)
            try setLatestPartialStructuredOutput(nil, for: threadID)
            try appendHistoryItem(.structuredOutput(.init(threadID: threadID, turnID: turnID,
                metadata: metadata, committedAt: Date())), threadID: threadID, createdAt: Date())
            updateThreadTimestamp(Date(), for: threadID)
            try await persistState()
        }
        if !duplicate { try await sink.committed(decoded) }
        return true
    }
}
