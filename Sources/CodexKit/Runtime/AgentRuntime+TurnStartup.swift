import Foundation

extension AgentRuntime {
    func beginTurnWithUnauthorizedRecovery(
        thread: AgentThread,
        history: [AgentMessage],
        providerContext: AgentProviderContext?,
        message: Request,
        resolvedInstructions: ResolvedAgentInstructions,
        resolvedTurnSkills: ResolvedTurnSkills,
        pendingUserMessage: AgentMessage?,
        responseContract: AgentResponseContract?,
        tools: [ToolDefinition],
        session: ChatGPTSession,
        allowsContextCompaction: Bool = true
    ) async throws -> (
        turnStream: AgentTurnStream,
        session: ChatGPTSession
    ) {
        do {
            let beginTurn = try await withUnauthorizedRecovery(
                initialSession: session
            ) { session in
                try await self.beginBackendTurn(
                    thread: thread,
                    history: history,
                    providerContext: providerContext,
                    message: message,
                    instructions: resolvedInstructions.text,
                    responseFormat: responseContract?.textFormat,
                    streamedStructuredOutput: responseContract?.streamedRequest,
                    tools: tools,
                    session: session
                )
            }
            return (beginTurn.result, beginTurn.session)
        } catch {
            guard allowsContextCompaction else {
                throw error
            }
            let compacted = try await maybeCompactThreadContextAfterContextFailure(
                thread: thread,
                request: message,
                pendingUserMessage: pendingUserMessage,
                resolvedInstructions: resolvedInstructions,
                resolvedTurnSkills: resolvedTurnSkills,
                tools: tools,
                session: session,
                error: error
            )
            guard compacted else {
                throw error
            }

            let beginTurn = try await withUnauthorizedRecovery(
                initialSession: session
            ) { session in
                try await self.beginBackendTurn(
                    thread: thread,
                    history: self.historyBeforePendingMessage(
                        in: thread.id,
                        pendingUserMessage: pendingUserMessage
                    ),
                    providerContext: self.providerContext(for: thread.id),
                    message: message,
                    instructions: resolvedInstructions.text,
                    responseFormat: responseContract?.textFormat,
                    streamedStructuredOutput: responseContract?.streamedRequest,
                    tools: tools,
                    session: session
                )
            }
            return (beginTurn.result, beginTurn.session)
        }
    }

    private func beginBackendTurn(
        thread: AgentThread,
        history: [AgentMessage],
        providerContext: AgentProviderContext?,
        message: Request,
        instructions: String,
        responseFormat: AgentStructuredOutputFormat?,
        streamedStructuredOutput: AgentStreamedStructuredOutputRequest?,
        tools: [ToolDefinition],
        session: ChatGPTSession
    ) async throws -> AgentTurnStream {
        let stream: AgentTurnStream
        if let contextBackend = backend as? any AgentBackendProviderContextSupporting {
            stream = try await contextBackend.beginTurn(
                thread: thread,
                history: history,
                providerContext: providerContext,
                message: message,
                instructions: instructions,
                responseFormat: responseFormat,
                streamedStructuredOutput: streamedStructuredOutput,
                tools: tools,
                session: session
            )
        } else {
            stream = try await backend.beginTurn(
            thread: thread,
            history: history,
            message: message,
            instructions: instructions,
            responseFormat: responseFormat,
            streamedStructuredOutput: streamedStructuredOutput,
            tools: tools,
            session: session
            )
        }
        do {
            try await stream.waitUntilReady()
            return stream
        } catch {
            stream.interrupt()
            throw error
        }
    }

}
