import Foundation

extension CodexResponsesBackend: AgentBackendTurnRecoverySupporting {
    public func resumeTurn(
        from checkpoint: AgentTurnRecoveryCheckpoint,
        history: [AgentMessage],
        tools: [ToolDefinition],
        session: ChatGPTSession
    ) async throws -> AgentTurnStream {
        guard checkpoint.providerID == CodexResponsesProviderState.providerID else {
            throw AgentRuntimeError(
                code: "turn_recovery_provider_mismatch",
                message: "The stored turn belongs to a different response provider."
            )
        }
        let payload = try CodexResponsesRecoveryPayload(jsonValue: checkpoint.payload)
        return CodexResponsesRecoveredTurnSession(
            configuration: configuration,
            logger: logger,
            checkpoint: checkpoint,
            payload: payload,
            history: history,
            urlSession: urlSession,
            encoder: encoder,
            decoder: decoder,
            tools: tools,
            session: session
        ).stream
    }
}

private struct CodexResponsesRecoveredTurnSession {
    let stream: AgentTurnStream

    init(
        configuration: CodexResponsesBackendConfiguration,
        logger: AgentLogger,
        checkpoint: AgentTurnRecoveryCheckpoint,
        payload: CodexResponsesRecoveryPayload,
        history: [AgentMessage],
        urlSession: URLSession,
        encoder: JSONEncoder,
        decoder: JSONDecoder,
        tools: [ToolDefinition],
        session: ChatGPTSession
    ) {
        let pendingToolResults = PendingToolResults()
        let turn = AgentTurn(
            id: checkpoint.turnID,
            threadID: checkpoint.threadID,
            startedAt: payload.turnStartedAt
        )

        let events = AsyncThrowingStream<AgentBackendEvent, Error> { continuation in
            continuation.yield(.turnStarted(turn))
            let runner = CodexResponsesTurnRunner(
                configuration: configuration,
                logger: logger,
                instructions: payload.instructions,
                responseContract: payload.responseContract,
                threadConfiguration: payload.threadConfiguration,
                urlSession: urlSession,
                encoder: encoder,
                decoder: decoder,
                threadID: checkpoint.threadID,
                turnID: checkpoint.turnID,
                turnStartedAt: payload.turnStartedAt,
                request: checkpoint.request,
                tools: tools,
                session: session,
                pendingToolResults: pendingToolResults,
                continuation: continuation
            )

            let producerTask = Task {
                do {
                    let result = try await runner.run(
                        resuming: payload,
                        history: history,
                        providerAttachments: checkpoint.providerAttachments
                    )
                    continuation.yield(
                        .providerContextUpdated(
                            threadID: checkpoint.threadID,
                            context: result.providerContext
                        )
                    )
                    continuation.yield(
                        .turnCompleted(
                            AgentTurnSummary(
                                threadID: checkpoint.threadID,
                                turnID: checkpoint.turnID,
                                usage: result.usage
                            )
                        )
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable termination in
                if case .cancelled = termination {
                    producerTask.cancel()
                }
            }
        }
        stream = AgentTurnStream(events: events) { result, invocationID in
            await pendingToolResults.resolve(result, for: invocationID)
        }
    }
}
