import Foundation

public enum CodexResponsesStateManagement: String, Codable, Hashable, Sendable {
    case clientManaged
    case serverManaged
}

public struct CodexResponsesBackendConfiguration: Sendable {
    public let baseURL: URL
    public let model: String
    public let reasoningEffort: ReasoningEffort
    public let instructions: String
    public let originator: String
    public let streamIdleTimeout: TimeInterval
    public let extraHeaders: [String: String]
    public let enableWebSearch: Bool
    public let enableImageGeneration: Bool
    public let imageGenerationOutputFormat: String
    public let stateManagement: CodexResponsesStateManagement
    public let requestRetryPolicy: RequestRetryPolicy
    public let logging: AgentLoggingConfiguration

    public var codexModel: CodexModel {
        CodexModel(rawValue: model)
    }

    public init(
        baseURL: URL = URL(string: "https://chatgpt.com/backend-api/codex")!,
        model: String = "gpt-5.6-sol",
        reasoningEffort: ReasoningEffort? = nil,
        instructions: String = """
        You are a helpful assistant embedded in an iOS app. Respond naturally, keep the user oriented, and use registered tools when they are helpful. Do not assume shell, terminal, repository, or desktop capabilities unless a host-defined tool explicitly provides them.
        """,
        originator: String = "codex_cli_rs",
        streamIdleTimeout: TimeInterval = 60,
        extraHeaders: [String: String] = [:],
        enableWebSearch: Bool = false,
        enableImageGeneration: Bool = false,
        imageGenerationOutputFormat: String = "png",
        stateManagement: CodexResponsesStateManagement = .clientManaged,
        requestRetryPolicy: RequestRetryPolicy = .default,
        logging: AgentLoggingConfiguration = .disabled
    ) {
        self.baseURL = baseURL
        self.model = model
        self.reasoningEffort = reasoningEffort
            ?? CodexModel(rawValue: model).info?.defaultReasoningEffort
            ?? .medium
        self.instructions = instructions
        self.originator = originator
        self.streamIdleTimeout = streamIdleTimeout
        self.extraHeaders = extraHeaders
        self.enableWebSearch = enableWebSearch
        self.enableImageGeneration = enableImageGeneration
        self.imageGenerationOutputFormat = imageGenerationOutputFormat
        self.stateManagement = stateManagement
        self.requestRetryPolicy = requestRetryPolicy
        self.logging = logging
    }

    public init(
        model: CodexModel,
        baseURL: URL = URL(string: "https://chatgpt.com/backend-api/codex")!,
        reasoningEffort: ReasoningEffort? = nil,
        instructions: String = """
        You are a helpful assistant embedded in an iOS app. Respond naturally, keep the user oriented, and use registered tools when they are helpful. Do not assume shell, terminal, repository, or desktop capabilities unless a host-defined tool explicitly provides them.
        """,
        originator: String = "codex_cli_rs",
        streamIdleTimeout: TimeInterval = 60,
        extraHeaders: [String: String] = [:],
        enableWebSearch: Bool = false,
        enableImageGeneration: Bool = false,
        imageGenerationOutputFormat: String = "png",
        stateManagement: CodexResponsesStateManagement = .clientManaged,
        requestRetryPolicy: RequestRetryPolicy = .default,
        logging: AgentLoggingConfiguration = .disabled
    ) {
        self.init(
            baseURL: baseURL,
            model: model.rawValue,
            reasoningEffort: reasoningEffort ?? model.info?.defaultReasoningEffort ?? .medium,
            instructions: instructions,
            originator: originator,
            streamIdleTimeout: streamIdleTimeout,
            extraHeaders: extraHeaders,
            enableWebSearch: enableWebSearch,
            enableImageGeneration: enableImageGeneration,
            imageGenerationOutputFormat: imageGenerationOutputFormat,
            stateManagement: stateManagement,
            requestRetryPolicy: requestRetryPolicy,
            logging: logging
        )
    }
}

extension CodexResponsesBackendConfiguration {
    var defaultThreadConfiguration: AgentThreadConfiguration {
        AgentThreadConfiguration(
            model: model,
            reasoningEffort: reasoningEffort
        )
    }

    func modelContextWindowTokenCount(for model: String) -> Int? {
        let normalizedModel = model.lowercased()
        if let contextWindowTokenCount = CodexModel(rawValue: normalizedModel).info?.contextWindowTokenCount {
            return contextWindowTokenCount
        }
        if normalizedModel == "gpt-5" {
            return 272_000
        }
        return nil
    }

    func usableContextWindowTokenCount(for model: String) -> Int? {
        guard let modelContextWindowTokenCount = modelContextWindowTokenCount(for: model) else {
            return nil
        }
        return (modelContextWindowTokenCount * 95) / 100
    }

    var modelContextWindowTokenCount: Int? {
        modelContextWindowTokenCount(for: model)
    }

    var usableContextWindowTokenCount: Int? {
        usableContextWindowTokenCount(for: model)
    }
}

public actor CodexResponsesBackend: AgentBackend {
    public let baseInstructions: String?
    public let defaultThreadConfiguration: AgentThreadConfiguration?

    let configuration: CodexResponsesBackendConfiguration
    let logger: AgentLogger
    let urlSession: URLSession
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    public init(
        configuration: CodexResponsesBackendConfiguration = CodexResponsesBackendConfiguration(),
        urlSession: URLSession = .shared
    ) {
        self.configuration = configuration
        self.logger = AgentLogger(configuration: configuration.logging)
        self.urlSession = urlSession
        self.baseInstructions = configuration.instructions
        self.defaultThreadConfiguration = configuration.defaultThreadConfiguration
    }

    public func createThread(session _: ChatGPTSession) async throws -> AgentThread {
        AgentThread(
            id: UUID().uuidString,
            configuration: configuration.defaultThreadConfiguration
        )
    }

    public func resumeThread(id: String, session _: ChatGPTSession) async throws -> AgentThread {
        AgentThread(
            id: id,
            configuration: configuration.defaultThreadConfiguration
        )
    }

    public func beginTurn(
        thread: AgentThread,
        history: [AgentMessage],
        message: Request,
        instructions: String,
        responseFormat: AgentStructuredOutputFormat?,
        streamedStructuredOutput: AgentStreamedStructuredOutputRequest?,
        tools: [ToolDefinition],
        session: ChatGPTSession
    ) async throws -> AgentTurnStream {
        try await beginTurn(
            thread: thread,
            history: history,
            providerContext: nil,
            message: message,
            instructions: instructions,
            responseFormat: responseFormat,
            streamedStructuredOutput: streamedStructuredOutput,
            tools: tools,
            session: session
        )
    }

    public func beginTurn(
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
        let responseContract: AgentResponseContract?
        if let streamedStructuredOutput {
            responseContract = AgentResponseContract(
                format: streamedStructuredOutput.responseFormat,
                deliveryMode: .streaming(options: streamedStructuredOutput.options)
            )
        } else if let responseFormat {
            responseContract = AgentResponseContract(format: responseFormat, deliveryMode: .oneShot)
        } else {
            responseContract = nil
        }
        return CodexResponsesTurnSession(
            configuration: configuration,
            logger: logger,
            instructions: instructions,
            responseContract: responseContract,
            urlSession: urlSession,
            encoder: encoder,
            decoder: decoder,
            thread: thread,
            history: history,
            providerContext: providerContext,
            message: message,
            tools: tools,
            session: session
        ).stream
    }
}

extension CodexResponsesBackend: AgentBackendProviderContextSupporting {}

extension CodexResponsesBackend: AgentBackendContextWindowProviding {
    public var modelContextWindowTokenCount: Int? {
        configuration.modelContextWindowTokenCount
    }

    public var usableContextWindowTokenCount: Int? {
        configuration.usableContextWindowTokenCount
    }

    public func modelContextWindowTokenCount(for model: String) async -> Int? {
        configuration.modelContextWindowTokenCount(for: model)
    }

    public func usableContextWindowTokenCount(for model: String) async -> Int? {
        configuration.usableContextWindowTokenCount(for: model)
    }
}

extension CodexResponsesBackend {
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

private struct CodexResponsesTurnSession {
    let stream: AgentTurnStream

    init(
        configuration: CodexResponsesBackendConfiguration,
        logger: AgentLogger,
        instructions: String,
        responseContract: AgentResponseContract?,
        urlSession: URLSession,
        encoder: JSONEncoder,
        decoder: JSONDecoder,
        thread: AgentThread,
        history: [AgentMessage],
        providerContext: AgentProviderContext?,
        message: Request,
        tools: [ToolDefinition],
        session: ChatGPTSession
    ) {
        let pendingToolResults = PendingToolResults()
        let turn = AgentTurn(id: UUID().uuidString, threadID: thread.id)
        let threadConfiguration = thread.configuration ?? configuration.defaultThreadConfiguration

        let events = AsyncThrowingStream<AgentBackendEvent, Error> { continuation in
            continuation.yield(.turnStarted(turn))
            let runner = CodexResponsesTurnRunner(
                configuration: configuration,
                logger: logger,
                instructions: instructions,
                responseContract: responseContract,
                threadConfiguration: threadConfiguration,
                urlSession: urlSession,
                encoder: encoder,
                decoder: decoder,
                threadID: thread.id,
                turnID: turn.id,
                turnStartedAt: turn.startedAt,
                request: message,
                tools: tools,
                session: session,
                pendingToolResults: pendingToolResults,
                continuation: continuation
            )

            let producerTask = Task {
                do {
                    let result = try await runner.run(
                        history: history,
                        providerContext: providerContext
                    )

                    logger.info(
                        .network,
                        "Backend turn completed.",
                        metadata: [
                            "thread_id": thread.id,
                            "turn_id": turn.id,
                            "output_tokens": "\(result.usage.outputTokens)"
                        ]
                    )

                    continuation.yield(
                        .providerContextUpdated(
                            threadID: thread.id,
                            context: result.providerContext
                        )
                    )

                    continuation.yield(
                        .turnCompleted(
                            AgentTurnSummary(
                                threadID: thread.id,
                                turnID: turn.id,
                                usage: result.usage
                            )
                        )
                    )
                    continuation.finish()
                } catch {
                    logger.error(
                        .network,
                        "Backend turn failed.",
                        metadata: [
                            "thread_id": thread.id,
                            "turn_id": turn.id,
                            "error": error.localizedDescription
                        ]
                    )
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
