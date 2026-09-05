import Foundation

extension AgentRuntime {
    // MARK: - Message Collection

    func collectFinalAssistantMessage(
        from stream: AsyncThrowingStream<AgentEvent, Error>
    ) async throws -> AgentMessage {
        var latestAssistantMessage: AgentMessage?

        for try await event in stream {
            guard case let .messageCommitted(message) = event,
                  message.role == .assistant else {
                continue
            }
            latestAssistantMessage = message
        }

        try Task.checkCancellation()
        guard let latestAssistantMessage else {
            throw AgentRuntimeError.assistantResponseMissing()
        }
        return latestAssistantMessage
    }

    func collectFinalAssistantTurn(
        from stream: AsyncThrowingStream<AgentEvent, Error>
    ) async throws -> (message: AgentMessage, summary: AgentTurnSummary) {
        var latestAssistantMessage: AgentMessage?
        var completedSummary: AgentTurnSummary?

        for try await event in stream {
            switch event {
            case let .messageCommitted(message) where message.role == .assistant:
                latestAssistantMessage = message
            case let .turnCompleted(summary):
                completedSummary = summary
            default:
                break
            }
        }

        try Task.checkCancellation()
        guard let latestAssistantMessage else {
            throw AgentRuntimeError.assistantResponseMissing()
        }
        guard let completedSummary else {
            throw AgentRuntimeError.turnSummaryMissing()
        }

        return (latestAssistantMessage, completedSummary)
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
        from turnStream: AgentTurnStream,
        for threadID: String
    ) async throws -> AgentMessage {
        var latestAssistantMessage: AgentMessage?
        var currentTurnID: String?

        for try await event in turnStream.events {
            switch event {
            case .progress, .rateLimitsUpdated, .userMessageAccepted:
                break
            case let .toolCallsRequested(invocations):
                for invocation in invocations {
                    try validateBackendTurnEvent(threadID: invocation.threadID, turnID: invocation.turnID,
                        expectedThreadID: threadID, currentTurnID: currentTurnID)
                    try await turnStream.submitToolResult(.failure(invocation: invocation,
                        message: "Automatic memory capture does not allow tool calls."), for: invocation.id)
                }
            case let .turnStarted(turn):
                try validateTurnStart(
                    turn,
                    expectedThreadID: threadID,
                    currentTurnID: currentTurnID
                )
                currentTurnID = turn.id

            case let .assistantMessageDelta(eventThreadID, eventTurnID, _):
                try validateBackendTurnEvent(
                    threadID: eventThreadID,
                    turnID: eventTurnID,
                    expectedThreadID: threadID,
                    currentTurnID: currentTurnID
                )

            case let .assistantMessageCompleted(message):
                try validateAssistantMessageEvent(
                    message,
                    expectedThreadID: threadID,
                    currentTurnID: currentTurnID
                )
                latestAssistantMessage = message

            case .structuredOutputPartial,
                 .structuredOutputCommitted,
                 .structuredOutputValidationFailed:
                try validateActiveTurn(
                    expectedThreadID: threadID,
                    currentTurnID: currentTurnID
                )

            case let .toolCallRequested(invocation):
                try validateBackendTurnEvent(
                    threadID: invocation.threadID,
                    turnID: invocation.turnID,
                    expectedThreadID: threadID,
                    currentTurnID: currentTurnID
                )
                try await turnStream.submitToolResult(
                    .failure(
                        invocation: invocation,
                        message: "Automatic memory capture does not allow tool calls."
                    ),
                    for: invocation.id
                )

            case let .providerContextUpdated(eventThreadID, _):
                try validateProviderContextEvent(
                    threadID: eventThreadID,
                    expectedThreadID: threadID,
                    currentTurnID: currentTurnID
                )

            case let .turnCompleted(summary):
                try Task.checkCancellation()
                try validateTurnCompletion(
                    summary,
                    expectedThreadID: threadID,
                    currentTurnID: currentTurnID
                )
                guard let latestAssistantMessage else {
                    throw AgentRuntimeError.assistantResponseMissing()
                }
                return latestAssistantMessage
            }
        }

        try Task.checkCancellation()
        guard let latestAssistantMessage else {
            throw AgentRuntimeError.assistantResponseMissing()
        }

        return latestAssistantMessage
    }
}
