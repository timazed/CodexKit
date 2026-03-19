import Foundation

public struct CodexResponsesBackendConfiguration: Sendable {
    public let baseURL: URL
    public let model: String
    public let instructions: String
    public let originator: String
    public let streamIdleTimeout: TimeInterval
    public let extraHeaders: [String: String]

    public init(
        baseURL: URL = URL(string: "https://chatgpt.com/backend-api/codex")!,
        model: String = "gpt-5",
        instructions: String = """
        You are a helpful assistant embedded in an iOS app. Respond naturally, keep the user oriented, and use registered tools when they are helpful. Do not assume shell, terminal, repository, or desktop capabilities unless a host-defined tool explicitly provides them.
        """,
        originator: String = "codex_cli_rs",
        streamIdleTimeout: TimeInterval = 60,
        extraHeaders: [String: String] = [:]
    ) {
        self.baseURL = baseURL
        self.model = model
        self.instructions = instructions
        self.originator = originator
        self.streamIdleTimeout = streamIdleTimeout
        self.extraHeaders = extraHeaders
    }
}

public actor CodexResponsesBackend: AgentBackend {
    private let configuration: CodexResponsesBackendConfiguration
    private let urlSession: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        configuration: CodexResponsesBackendConfiguration = CodexResponsesBackendConfiguration(),
        urlSession: URLSession = .shared
    ) {
        self.configuration = configuration
        self.urlSession = urlSession
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
        tools: [ToolDefinition],
        session: ChatGPTSession
    ) async throws -> any AgentTurnStreaming {
        CodexResponsesTurnSession(
            configuration: configuration,
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

final class CodexResponsesTurnSession: AgentTurnStreaming, @unchecked Sendable {
    let events: AsyncThrowingStream<AgentBackendEvent, Error>

    private let pendingToolResults: PendingToolResults

    init(
        configuration: CodexResponsesBackendConfiguration,
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
                    text: newMessage.text
                )
            )
        )

        var aggregateUsage = AgentUsage()
        var shouldContinue = true

        while shouldContinue {
            shouldContinue = false

            let request = try buildURLRequest(
                configuration: configuration,
                threadID: threadID,
                items: workingHistory,
                tools: tools,
                session: session,
                encoder: encoder
            )

            let stream = try await streamEvents(
                request: request,
                configuration: configuration,
                urlSession: urlSession,
                decoder: decoder
            )

            var sawToolCall = false

            for try await event in stream {
                switch event {
                case let .assistantTextDelta(delta):
                    continuation.yield(
                        .assistantMessageDelta(
                            threadID: threadID,
                            turnID: turnID,
                            delta: delta
                        )
                    )

                case let .assistantMessage(text):
                    let message = AgentMessage(
                        threadID: threadID,
                        role: .assistant,
                        text: text
                    )
                    workingHistory.append(.assistantMessage(message))
                    continuation.yield(.assistantMessageCompleted(message))

                case let .functionCall(functionCall):
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

            shouldContinue = sawToolCall
        }

        return aggregateUsage
    }

    private static func buildURLRequest(
        configuration: CodexResponsesBackendConfiguration,
        threadID: String,
        items: [WorkingHistoryItem],
        tools: [ToolDefinition],
        session: ChatGPTSession,
        encoder: JSONEncoder
    ) throws -> URLRequest {
        let requestBody = ResponsesRequestBody(
            model: configuration.model,
            instructions: configuration.instructions,
            input: items.map(\.jsonValue),
            tools: tools.map { $0.responsesJSONValue },
            toolChoice: "auto",
            parallelToolCalls: false,
            store: false,
            stream: true,
            include: [],
            promptCacheKey: threadID
        )

        var request = URLRequest(url: configuration.baseURL.appendingPathComponent("responses"))
        request.httpMethod = "POST"
        request.httpBody = try encoder.encode(requestBody)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(session.account.id, forHTTPHeaderField: "ChatGPT-Account-ID")
        request.setValue(threadID, forHTTPHeaderField: "session_id")
        request.setValue(threadID, forHTTPHeaderField: "x-client-request-id")
        request.setValue(configuration.originator, forHTTPHeaderField: "originator")

        for (header, value) in configuration.extraHeaders {
            request.setValue(value, forHTTPHeaderField: header)
        }

        return request
    }

    private static func streamEvents(
        request: URLRequest,
        configuration: CodexResponsesBackendConfiguration,
        urlSession: URLSession,
        decoder: JSONDecoder
    ) async throws -> AsyncThrowingStream<CodexResponsesStreamEvent, Error> {
        let (bytes, response) = try await urlSession.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AgentRuntimeError(
                code: "responses_invalid_response",
                message: "The ChatGPT responses endpoint returned an invalid response."
            )
        }

        if !(200 ..< 300).contains(httpResponse.statusCode) {
            let bodyData = try await readAll(bytes)
            let body = String(data: bodyData, encoding: .utf8) ?? "Unknown error"
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw AgentRuntimeError.unauthorized(body)
            }
            throw AgentRuntimeError(
                code: "responses_request_failed",
                message: "The ChatGPT responses request failed with status \(httpResponse.statusCode): \(body)"
            )
        }

        return AsyncThrowingStream { continuation in
            Task {
                var parser = SSEEventParser()

                do {
                    var lineBuffer = Data()

                    for try await byte in bytes {
                        if byte == UInt8(ascii: "\n") {
                            var line = String(decoding: lineBuffer, as: UTF8.self)
                            if line.hasSuffix("\r") {
                                line.removeLast()
                            }
                            lineBuffer.removeAll(keepingCapacity: true)

                            if let payload = parser.consume(line: line) {
                                if let event = try parseStreamEvent(
                                    from: payload,
                                    decoder: decoder
                                ) {
                                    continuation.yield(event)
                                }
                            }
                            continue
                        }

                        lineBuffer.append(byte)
                    }

                    if !lineBuffer.isEmpty {
                        var line = String(decoding: lineBuffer, as: UTF8.self)
                        if line.hasSuffix("\r") {
                            line.removeLast()
                        }
                        if let payload = parser.consume(line: line) {
                            if let event = try parseStreamEvent(
                                from: payload,
                                decoder: decoder
                            ) {
                                continuation.yield(event)
                            }
                        }
                    }

                    if let payload = parser.finish(),
                       let event = try parseStreamEvent(from: payload, decoder: decoder) {
                        continuation.yield(event)
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private static func parseStreamEvent(
        from payload: SSEEventPayload,
        decoder: JSONDecoder
    ) throws -> CodexResponsesStreamEvent? {
        guard !payload.data.isEmpty else {
            return nil
        }

        let envelope = try decoder.decode(
            StreamEnvelope.self,
            from: Data(payload.data.utf8)
        )

        switch envelope.type {
        case "response.output_text.delta":
            return envelope.delta.map(CodexResponsesStreamEvent.assistantTextDelta)

        case "response.output_item.done":
            guard let item = envelope.item else {
                return nil
            }

            switch item {
            case let .message(message):
                let text = message.content
                    .compactMap(\.text)
                    .joined()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : .assistantMessage(text)

            case let .functionCall(functionCall):
                return .functionCall(
                    FunctionCallRecord(
                        name: functionCall.name,
                        callID: functionCall.callID,
                        argumentsRaw: functionCall.arguments
                    )
                )

            case .other:
                return nil
            }

        case "response.completed":
            let usage = envelope.response?.usage?.assistantUsage ?? AgentUsage()
            return .completed(usage)

        case "response.failed":
            let message = envelope.response?.error?.message ?? "The ChatGPT responses stream failed."
            throw AgentRuntimeError(code: "responses_stream_failed", message: message)

        case "response.incomplete":
            let reason = envelope.response?.incompleteDetails?.reason ?? "unknown"
            throw AgentRuntimeError(
                code: "responses_stream_incomplete",
                message: "The ChatGPT responses stream completed early: \(reason)."
            )

        default:
            return nil
        }
    }

    private static func readAll(_ bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
        }
        return data
    }

    private static func toolOutputText(from result: ToolResultEnvelope) -> String {
        if let primaryText = result.primaryText, !primaryText.isEmpty {
            return primaryText
        }
        if let errorMessage = result.errorMessage, !errorMessage.isEmpty {
            return errorMessage
        }
        return result.success ? "Tool execution completed." : "Tool execution failed."
    }
}

private struct ResponsesRequestBody: Encodable {
    let model: String
    let instructions: String
    let input: [JSONValue]
    let tools: [JSONValue]
    let toolChoice: String
    let parallelToolCalls: Bool
    let store: Bool
    let stream: Bool
    let include: [String]
    let promptCacheKey: String?

    enum CodingKeys: String, CodingKey {
        case model
        case instructions
        case input
        case tools
        case toolChoice = "tool_choice"
        case parallelToolCalls = "parallel_tool_calls"
        case store
        case stream
        case include
        case promptCacheKey = "prompt_cache_key"
    }
}

private enum WorkingHistoryItem: Sendable {
    case visibleMessage(AgentMessage)
    case userMessage(AgentMessage)
    case assistantMessage(AgentMessage)
    case functionCall(FunctionCallRecord)
    case functionCallOutput(callID: String, output: String)

    var jsonValue: JSONValue {
        switch self {
        case let .visibleMessage(message):
            Self.messageJSONValue(for: message)
        case let .userMessage(message):
            Self.messageJSONValue(for: message)
        case let .assistantMessage(message):
            Self.messageJSONValue(for: message)
        case let .functionCall(functionCall):
            .object([
                "type": .string("function_call"),
                "name": .string(functionCall.name),
                "arguments": .string(functionCall.argumentsRaw),
                "call_id": .string(functionCall.callID),
            ])
        case let .functionCallOutput(callID, output):
            .object([
                "type": .string("function_call_output"),
                "call_id": .string(callID),
                "output": .string(output),
            ])
        }
    }

    private static func messageJSONValue(for message: AgentMessage) -> JSONValue {
        let contentType: JSONValue = switch message.role {
        case .assistant:
            .string("output_text")
        default:
            .string("input_text")
        }

        let roleValue: String = switch message.role {
        case .assistant:
            "assistant"
        case .system:
            "system"
        case .tool:
            "assistant"
        case .user:
            "user"
        }

        return .object([
            "type": .string("message"),
            "role": .string(roleValue),
            "content": .array([
                .object([
                    "type": contentType,
                    "text": .string(message.text),
                ]),
            ]),
        ])
    }
}

private struct FunctionCallRecord: Sendable {
    let name: String
    let callID: String
    let argumentsRaw: String

    var arguments: JSONValue {
        guard let data = argumentsRaw.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data)
        else {
            return .string(argumentsRaw)
        }
        return value
    }
}

private enum CodexResponsesStreamEvent: Sendable {
    case assistantTextDelta(String)
    case assistantMessage(String)
    case functionCall(FunctionCallRecord)
    case completed(AgentUsage)
}

private struct PendingToolResults: Sendable {
    private actor Storage {
        private var waiting: [String: CheckedContinuation<ToolResultEnvelope, Error>] = [:]
        private var resolved: [String: ToolResultEnvelope] = [:]

        func wait(for invocationID: String) async throws -> ToolResultEnvelope {
            if let resolved = resolved.removeValue(forKey: invocationID) {
                return resolved
            }

            return try await withCheckedThrowingContinuation { continuation in
                waiting[invocationID] = continuation
            }
        }

        func resolve(_ result: ToolResultEnvelope, for invocationID: String) {
            if let continuation = waiting.removeValue(forKey: invocationID) {
                continuation.resume(returning: result)
            } else {
                resolved[invocationID] = result
            }
        }
    }

    private let storage = Storage()

    func wait(for invocationID: String) async throws -> ToolResultEnvelope {
        try await storage.wait(for: invocationID)
    }

    func resolve(_ result: ToolResultEnvelope, for invocationID: String) async {
        await storage.resolve(result, for: invocationID)
    }
}

private extension ToolDefinition {
    var responsesJSONValue: JSONValue {
        .object([
            "type": .string("function"),
            "name": .string(name),
            "description": .string(description),
            "strict": .bool(false),
            "parameters": normalizedSchema,
        ])
    }

    var normalizedSchema: JSONValue {
        guard case var .object(schema) = inputSchema else {
            return inputSchema
        }
        if schema["properties"] == nil {
            schema["properties"] = .object([:])
        }
        return .object(schema)
    }
}

private struct SSEEventPayload {
    let event: String?
    let data: String
}

private struct SSEEventParser {
    private var eventName: String?
    private var dataLines: [String] = []

    mutating func consume(line: String) -> SSEEventPayload? {
        if line.isEmpty {
            return flush()
        }

        if line.hasPrefix("event:") {
            eventName = Self.trimmedFieldValue(from: line)
        } else if line.hasPrefix("data:") {
            dataLines.append(Self.trimmedFieldValue(from: line))
        }

        return nil
    }

    mutating func finish() -> SSEEventPayload? {
        flush()
    }

    private mutating func flush() -> SSEEventPayload? {
        guard !dataLines.isEmpty else {
            eventName = nil
            return nil
        }

        let payload = SSEEventPayload(
            event: eventName,
            data: dataLines.joined(separator: "\n")
        )
        eventName = nil
        dataLines.removeAll(keepingCapacity: true)
        return payload
    }

    private static func trimmedFieldValue(from line: String) -> String {
        let value = line.drop { $0 != ":" }
        return value.dropFirst().trimmingCharacters(in: .whitespaces)
    }
}

private struct StreamEnvelope: Decodable {
    let type: String
    let delta: String?
    let item: StreamItem?
    let response: StreamResponsePayload?
}

private enum StreamItem: Decodable {
    case message(StreamMessageItem)
    case functionCall(StreamFunctionCallItem)
    case other

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let object = try container.decode([String: JSONValue].self)
        let type = object["type"]?.stringValue

        switch type {
        case "message":
            let data = try JSONEncoder().encode(object)
            self = .message(try JSONDecoder().decode(StreamMessageItem.self, from: data))
        case "function_call":
            let data = try JSONEncoder().encode(object)
            self = .functionCall(try JSONDecoder().decode(StreamFunctionCallItem.self, from: data))
        default:
            self = .other
        }
    }
}

private struct StreamMessageItem: Decodable {
    let role: String
    let content: [StreamMessageContent]
}

private struct StreamMessageContent: Decodable {
    let type: String
    let text: String?
}

private struct StreamFunctionCallItem: Decodable {
    let name: String
    let arguments: String
    let callID: String

    enum CodingKeys: String, CodingKey {
        case name
        case arguments
        case callID = "call_id"
    }
}

private struct StreamResponsePayload: Decodable {
    let id: String?
    let usage: StreamUsage?
    let error: StreamErrorPayload?
    let incompleteDetails: StreamIncompleteDetails?

    enum CodingKeys: String, CodingKey {
        case id
        case usage
        case error
        case incompleteDetails = "incomplete_details"
    }
}

private struct StreamUsage: Decodable {
    let inputTokens: Int
    let inputTokensDetails: StreamInputTokenDetails?
    let outputTokens: Int

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case inputTokensDetails = "input_tokens_details"
        case outputTokens = "output_tokens"
    }

    var assistantUsage: AgentUsage {
        AgentUsage(
            inputTokens: inputTokens,
            cachedInputTokens: inputTokensDetails?.cachedTokens ?? 0,
            outputTokens: outputTokens
        )
    }
}

private struct StreamInputTokenDetails: Decodable {
    let cachedTokens: Int

    enum CodingKeys: String, CodingKey {
        case cachedTokens = "cached_tokens"
    }
}

private struct StreamErrorPayload: Decodable {
    let message: String?
}

private struct StreamIncompleteDetails: Decodable {
    let reason: String?
}
