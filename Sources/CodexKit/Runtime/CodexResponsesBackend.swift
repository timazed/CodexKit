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
    public let logging: AgentLoggingConfiguration

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
        requestRetryPolicy: RequestRetryPolicy = .default,
        logging: AgentLoggingConfiguration = .disabled
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
        self.logging = logging
    }
}

extension CodexResponsesBackendConfiguration {
    var modelContextWindowTokenCount: Int? {
        let normalizedModel = model.lowercased()
        if normalizedModel.hasPrefix("gpt-5") {
            return 272_000
        }
        return nil
    }

    var usableContextWindowTokenCount: Int? {
        guard let modelContextWindowTokenCount else {
            return nil
        }
        return (modelContextWindowTokenCount * 95) / 100
    }
}

public actor CodexResponsesBackend: AgentBackend {
    public nonisolated let baseInstructions: String?

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
        message: Request,
        instructions: String,
        responseFormat: AgentStructuredOutputFormat?,
        streamedStructuredOutput: AgentStreamedStructuredOutputRequest?,
        tools: [ToolDefinition],
        session: ChatGPTSession
    ) async throws -> any AgentTurnStreaming {
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
            message: message,
            tools: tools,
            session: session
        )
    }
}

extension CodexResponsesBackend: AgentBackendContextWindowProviding {
    public nonisolated var modelContextWindowTokenCount: Int? {
        configuration.modelContextWindowTokenCount
    }

    public nonisolated var usableContextWindowTokenCount: Int? {
        configuration.usableContextWindowTokenCount
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

final class CodexResponsesTurnSession: AgentTurnStreaming, @unchecked Sendable {
    let events: AsyncThrowingStream<AgentBackendEvent, Error>

    private let logger: AgentLogger
    private let pendingToolResults: PendingToolResults

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
        message: Request,
        tools: [ToolDefinition],
        session: ChatGPTSession
    ) {
        self.logger = logger
        let pendingToolResults = PendingToolResults()
        self.pendingToolResults = pendingToolResults
        let turn = AgentTurn(id: UUID().uuidString, threadID: thread.id)

        events = AsyncThrowingStream { continuation in
            continuation.yield(.turnStarted(turn))
            let runner = CodexResponsesTurnRunner(
                configuration: configuration,
                logger: logger,
                instructions: instructions,
                responseContract: responseContract,
                urlSession: urlSession,
                encoder: encoder,
                decoder: decoder,
                threadID: thread.id,
                turnID: turn.id,
                tools: tools,
                session: session,
                pendingToolResults: pendingToolResults,
                continuation: continuation
            )

            Task {
                do {
                    let usage = try await runner.run(
                        history: history,
                        newMessage: message
                    )

                    logger.info(
                        .network,
                        "Backend turn completed.",
                        metadata: [
                            "thread_id": thread.id,
                            "turn_id": turn.id,
                            "output_tokens": "\(usage.outputTokens)"
                        ]
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
        }
    }

    func submitToolResult(
        _ result: ToolResultEnvelope,
        for invocationID: String
    ) async throws {
        await pendingToolResults.resolve(result, for: invocationID)
    }
}
