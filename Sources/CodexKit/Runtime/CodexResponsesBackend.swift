import Foundation

public struct CodexResponsesBackendConfiguration: Sendable {
    public let baseURL: URL
    public let model: String
    public let reasoningEffort: ReasoningEffort
    public let instructions: String
    public let originator: String
    public let streamIdleTimeout: TimeInterval
    public let extraHeaders: [String: String]
    public let enableWebSearch: Bool
    public let requestRetryPolicy: RequestRetryPolicy

    public init(
        baseURL: URL = URL(string: "https://chatgpt.com/backend-api/codex")!,
        model: String = "gpt-5",
        reasoningEffort: ReasoningEffort = .medium,
        instructions: String = """
        You are a helpful assistant embedded in an iOS app. Respond naturally, keep the user oriented, and use registered tools when they are helpful. Do not assume shell, terminal, repository, or desktop capabilities unless a host-defined tool explicitly provides them.
        """,
        originator: String = "codex_cli_rs",
        streamIdleTimeout: TimeInterval = 60,
        extraHeaders: [String: String] = [:],
        enableWebSearch: Bool = false,
        requestRetryPolicy: RequestRetryPolicy = .default
    ) {
        self.baseURL = baseURL
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.instructions = instructions
        self.originator = originator
        self.streamIdleTimeout = streamIdleTimeout
        self.extraHeaders = extraHeaders
        self.enableWebSearch = enableWebSearch
        self.requestRetryPolicy = requestRetryPolicy
    }
}

public actor CodexResponsesBackend: AgentBackend {
    public nonisolated let baseInstructions: String?

    let configuration: CodexResponsesBackendConfiguration
    let urlSession: URLSession
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    public init(
        configuration: CodexResponsesBackendConfiguration = CodexResponsesBackendConfiguration(),
        urlSession: URLSession = .shared
    ) {
        self.configuration = configuration
        self.urlSession = urlSession
        self.baseInstructions = configuration.instructions
    }

    public func createThread(session _: ChatGPTSession) async throws -> AgentThread {
        AgentThread(id: UUID().uuidString)
    }

    public func resumeThread(id: String, session _: ChatGPTSession) async throws -> AgentThread {
        AgentThread(id: id)
    }

    public func beginTurn(
        thread: AgentThread,
        history: [AgentMessage],
        message: UserMessageRequest,
        instructions: String,
        responseFormat: AgentStructuredOutputFormat?,
        streamedStructuredOutput: AgentStreamedStructuredOutputRequest?,
        tools: [ToolDefinition],
        session: ChatGPTSession
    ) async throws -> any AgentTurnStreaming {
        CodexResponsesTurnSession(
            configuration: configuration,
            instructions: instructions,
            responseFormat: responseFormat,
            streamedStructuredOutput: streamedStructuredOutput,
            urlSession: urlSession,
            encoder: encoder,
            decoder: decoder,
            thread: thread,
            history: history,
            message: message,
            tools: tools,
            session: session
        )
    }
}

private extension CodexResponsesBackend {
    static func structuredMetadata(
        from text: String,
        responseFormat: AgentStructuredOutputFormat?
    ) -> AgentStructuredOutputMetadata? {
        guard let responseFormat else {
            return nil
        }

        let payloadText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = payloadText.data(using: .utf8),
              let payload = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return nil
        }

        return AgentStructuredOutputMetadata(
            formatName: responseFormat.name,
            payload: payload
        )
    }
}

final class CodexResponsesTurnSession: AgentTurnStreaming, @unchecked Sendable {
    let events: AsyncThrowingStream<AgentBackendEvent, Error>

    private let pendingToolResults: PendingToolResults

    init(
        configuration: CodexResponsesBackendConfiguration,
        instructions: String,
        responseFormat: AgentStructuredOutputFormat?,
        streamedStructuredOutput: AgentStreamedStructuredOutputRequest?,
        urlSession: URLSession,
        encoder: JSONEncoder,
        decoder: JSONDecoder,
        thread: AgentThread,
        history: [AgentMessage],
        message: UserMessageRequest,
        tools: [ToolDefinition],
        session: ChatGPTSession
    ) {
        let pendingToolResults = PendingToolResults()
        self.pendingToolResults = pendingToolResults
        let turn = AgentTurn(id: UUID().uuidString, threadID: thread.id)

        events = AsyncThrowingStream { continuation in
            continuation.yield(.turnStarted(turn))

            Task {
                do {
                    let usage = try await Self.runTurnLoop(
                        configuration: configuration,
                        instructions: instructions,
                        responseFormat: responseFormat,
                        streamedStructuredOutput: streamedStructuredOutput,
                        urlSession: urlSession,
                        encoder: encoder,
                        decoder: decoder,
                        threadID: thread.id,
                        turnID: turn.id,
                        history: history,
                        newMessage: message,
                        tools: tools,
                        session: session,
                        pendingToolResults: pendingToolResults,
                        continuation: continuation
                    )

                    continuation.yield(
                        .turnCompleted(
                            AgentTurnSummary(
                                threadID: thread.id,
                                turnID: turn.id,
                                usage: usage
                            )
                        )
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func submitToolResult(
        _ result: ToolResultEnvelope,
        for invocationID: String
    ) async throws {
        await pendingToolResults.resolve(result, for: invocationID)
    }

    private static func runTurnLoop(
        configuration: CodexResponsesBackendConfiguration,
        instructions: String,
        responseFormat: AgentStructuredOutputFormat?,
        streamedStructuredOutput: AgentStreamedStructuredOutputRequest?,
        urlSession: URLSession,
        encoder: JSONEncoder,
        decoder: JSONDecoder,
        threadID: String,
        turnID: String,
        history: [AgentMessage],
        newMessage: UserMessageRequest,
        tools: [ToolDefinition],
        session: ChatGPTSession,
        pendingToolResults: PendingToolResults,
        continuation: AsyncThrowingStream<AgentBackendEvent, Error>.Continuation
    ) async throws -> AgentUsage {
        var workingHistory = history.map(WorkingHistoryItem.visibleMessage)
        workingHistory.append(
            .userMessage(
                AgentMessage(
                    threadID: threadID,
                    role: .user,
                    text: newMessage.text,
                    images: newMessage.images
                )
            )
        )

        var aggregateUsage = AgentUsage()
        var shouldContinue = true
        var pendingToolImages: [AgentImageAttachment] = []
        var pendingToolFallbackTexts: [String] = []
        var structuredParser = CodexResponsesStructuredStreamParser()
        var pendingStructuredOutputMetadata: AgentStructuredOutputMetadata?

        while shouldContinue {
            shouldContinue = false
            var sawToolCall = false
            let retryPolicy = configuration.requestRetryPolicy
            var attempt = 1

            retryLoop: while true {
                var emittedRetryUnsafeOutput = false

                do {
                    let request = try buildURLRequest(
                        configuration: configuration,
                        instructions: instructions,
                        responseFormat: responseFormat,
                        streamedStructuredOutput: streamedStructuredOutput,
                        threadID: threadID,
                        items: workingHistory,
                        tools: tools,
                        session: session,
                        encoder: encoder
                    )

                    let stream = try await streamEvents(
                        request: request,
                        urlSession: urlSession,
                        decoder: decoder
                    )

                    for try await event in stream {
                        switch event {
                        case let .assistantTextDelta(delta):
                            emittedRetryUnsafeOutput = true
                            if streamedStructuredOutput != nil {
                                for parsedEvent in structuredParser.consume(delta: delta) {
                                    switch parsedEvent {
                                    case let .visibleText(visibleDelta):
                                        guard !visibleDelta.isEmpty else {
                                            continue
                                        }
                                        continuation.yield(
                                            .assistantMessageDelta(
                                                threadID: threadID,
                                                turnID: turnID,
                                                delta: visibleDelta
                                            )
                                        )
                                    case let .structuredOutputPartial(value):
                                        continuation.yield(.structuredOutputPartial(value))
                                    case let .structuredOutputValidationFailed(validationFailure):
                                        continuation.yield(.structuredOutputValidationFailed(validationFailure))
                                    }
                                }
                            } else {
                                continuation.yield(
                                    .assistantMessageDelta(
                                        threadID: threadID,
                                        turnID: turnID,
                                        delta: delta
                                    )
                                )
                            }

                        case let .assistantMessage(messageTemplate):
                            emittedRetryUnsafeOutput = true

                            let normalizedMessage: AgentMessage
                            if let streamedStructuredOutput {
                                let extraction = structuredParser.finalize(rawMessage: messageTemplate.text)

                                switch extraction.finalResult {
                                case .none:
                                    break
                                case let .committed(value):
                                    pendingStructuredOutputMetadata = AgentStructuredOutputMetadata(
                                        formatName: streamedStructuredOutput.responseFormat.name,
                                        payload: value
                                    )
                                    continuation.yield(.structuredOutputCommitted(value))
                                case let .invalid(validationFailure):
                                    continuation.yield(.structuredOutputValidationFailed(validationFailure))
                                    throw AgentRuntimeError.structuredOutputInvalid(
                                        stage: validationFailure.stage,
                                        underlyingMessage: validationFailure.message
                                    )
                                }

                                normalizedMessage = AgentMessage(
                                    threadID: threadID,
                                    role: .assistant,
                                    text: extraction.visibleText,
                                    images: messageTemplate.images
                                )
                            } else {
                                normalizedMessage = AgentMessage(
                                    threadID: threadID,
                                    role: .assistant,
                                    text: messageTemplate.text,
                                    images: messageTemplate.images
                                )
                            }

                            let assistantText: String
                            if normalizedMessage.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                               !pendingToolFallbackTexts.isEmpty {
                                assistantText = pendingToolFallbackTexts.joined(separator: "\n\n")
                            } else {
                                assistantText = normalizedMessage.text
                            }

                            let mergedImages = (normalizedMessage.images + pendingToolImages).uniqued()
                            let message = AgentMessage(
                                threadID: threadID,
                                role: .assistant,
                                text: assistantText,
                                images: mergedImages,
                                structuredOutput: pendingStructuredOutputMetadata
                                    ?? CodexResponsesBackend.structuredMetadata(
                                        from: assistantText,
                                        responseFormat: responseFormat
                                    )
                            )
                            workingHistory.append(.assistantMessage(message))
                            continuation.yield(.assistantMessageCompleted(message))
                            pendingToolImages.removeAll(keepingCapacity: true)
                            pendingToolFallbackTexts.removeAll(keepingCapacity: true)
                            pendingStructuredOutputMetadata = nil

                        case let .structuredOutputPartial(value):
                            continuation.yield(.structuredOutputPartial(value))

                        case let .structuredOutputCommitted(value):
                            continuation.yield(.structuredOutputCommitted(value))

                        case let .structuredOutputValidationFailed(validationFailure):
                            continuation.yield(.structuredOutputValidationFailed(validationFailure))

                        case let .functionCall(functionCall):
                            emittedRetryUnsafeOutput = true
                            sawToolCall = true
                            workingHistory.append(.functionCall(functionCall))

                            let invocation = ToolInvocation(
                                id: functionCall.callID,
                                threadID: threadID,
                                turnID: turnID,
                                toolName: functionCall.name,
                                arguments: functionCall.arguments
                            )

                            continuation.yield(.toolCallRequested(invocation))
                            let toolResult = try await pendingToolResults.wait(for: invocation.id)
                            let toolImages = await toolOutputImages(from: toolResult, urlSession: urlSession)
                            pendingToolImages.append(contentsOf: toolImages)
                            pendingToolImages = pendingToolImages.uniqued()

                            if let primaryText = toolResult.primaryText?
                                .trimmingCharacters(in: .whitespacesAndNewlines),
                               !primaryText.isEmpty {
                                pendingToolFallbackTexts.append(primaryText)
                            }

                            workingHistory.append(
                                .functionCallOutput(
                                    callID: invocation.id,
                                    output: toolOutputText(from: toolResult)
                                )
                            )

                        case let .completed(usage):
                            aggregateUsage.inputTokens += usage.inputTokens
                            aggregateUsage.cachedInputTokens += usage.cachedInputTokens
                            aggregateUsage.outputTokens += usage.outputTokens
                        }
                    }

                    break retryLoop
                } catch {
                    guard !emittedRetryUnsafeOutput,
                          attempt < retryPolicy.maxAttempts,
                          shouldRetry(error, policy: retryPolicy)
                    else {
                        throw error
                    }

                    let delay = retryPolicy.delayBeforeRetry(attempt: attempt)
                    if delay > 0 {
                        let nanoseconds = UInt64((delay * 1_000_000_000).rounded())
                        try await Task.sleep(nanoseconds: nanoseconds)
                    }
                    attempt += 1
                }
            }

            shouldContinue = sawToolCall
            if !shouldContinue, (!pendingToolImages.isEmpty || !pendingToolFallbackTexts.isEmpty) {
                let message = AgentMessage(
                    threadID: threadID,
                    role: .assistant,
                    text: pendingToolFallbackTexts.joined(separator: "\n\n"),
                    images: pendingToolImages
                )
                workingHistory.append(.assistantMessage(message))
                continuation.yield(.assistantMessageCompleted(message))
                pendingToolImages.removeAll(keepingCapacity: true)
                pendingToolFallbackTexts.removeAll(keepingCapacity: true)
            }
        }

        return aggregateUsage
    }
}
