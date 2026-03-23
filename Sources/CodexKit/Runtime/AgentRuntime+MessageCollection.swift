import Foundation

extension AgentRuntime {
    // MARK: - Message Collection

    func collectFinalAssistantMessage(
        from stream: AsyncThrowingStream<AgentEvent, Error>
    ) async throws -> AgentMessage {
        var latestAssistantMessage: AgentMessage?

        for try await event in stream {
            guard case let .messageCommitted(message) = event,
                  message.role == .assistant
            else {
                continue
            }

            latestAssistantMessage = message
        }

        guard let latestAssistantMessage else {
            throw AgentRuntimeError.assistantResponseMissing()
        }

        return latestAssistantMessage
    }

    func decodeStructuredValue<Output: Decodable & Sendable>(
        _ value: JSONValue,
        as outputType: Output.Type,
        decoder: JSONDecoder
    ) throws -> Output {
        let payload = try JSONEncoder().encode(value)
        do {
            return try decoder.decode(outputType, from: payload)
        } catch {
            throw AgentRuntimeError.structuredOutputDecodingFailed(
                typeName: String(describing: outputType),
                underlyingMessage: error.localizedDescription
            )
        }
    }

    func collectFinalAssistantMessage(
        from turnStream: any AgentTurnStreaming
    ) async throws -> AgentMessage {
        var latestAssistantMessage: AgentMessage?

        for try await event in turnStream.events {
            switch event {
            case let .assistantMessageCompleted(message):
                if message.role == .assistant {
                    latestAssistantMessage = message
                }

            case let .toolCallRequested(invocation):
                try await turnStream.submitToolResult(
                    .failure(
                        invocation: invocation,
                        message: "Automatic memory capture does not allow tool calls."
                    ),
                    for: invocation.id
                )

            default:
                break
            }
        }

        guard let latestAssistantMessage else {
            throw AgentRuntimeError.assistantResponseMissing()
        }

        return latestAssistantMessage
    }
}
