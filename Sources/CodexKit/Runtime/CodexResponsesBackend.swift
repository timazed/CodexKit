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
        tools: [ToolDefinition],
        session: ChatGPTSession
    ) async throws -> any AgentTurnStreaming {
        CodexResponsesTurnSession(
            configuration: configuration,
            instructions: instructions,
            responseFormat: responseFormat,
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
        instructions: String,
        responseFormat: AgentStructuredOutputFormat?,
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
                            continuation.yield(
                                .assistantMessageDelta(
                                    threadID: threadID,
                                    turnID: turnID,
                                    delta: delta
                                )
                            )

                        case let .assistantMessage(messageTemplate):
                            emittedRetryUnsafeOutput = true

                            let assistantText: String
                            if messageTemplate.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                               !pendingToolFallbackTexts.isEmpty {
                                assistantText = pendingToolFallbackTexts.joined(separator: "\n\n")
                            } else {
                                assistantText = messageTemplate.text
                            }

                            let mergedImages = (messageTemplate.images + pendingToolImages).uniqued()
                            let message = AgentMessage(
                                threadID: threadID,
                                role: .assistant,
                                text: assistantText,
                                images: mergedImages
                            )
                            workingHistory.append(.assistantMessage(message))
                            continuation.yield(.assistantMessageCompleted(message))
                            pendingToolImages.removeAll(keepingCapacity: true)
                            pendingToolFallbackTexts.removeAll(keepingCapacity: true)

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

    private static func buildURLRequest(
        configuration: CodexResponsesBackendConfiguration,
        instructions: String,
        responseFormat: AgentStructuredOutputFormat?,
        threadID: String,
        items: [WorkingHistoryItem],
        tools: [ToolDefinition],
        session: ChatGPTSession,
        encoder: JSONEncoder
    ) throws -> URLRequest {
        let requestBody = ResponsesRequestBody(
            model: configuration.model,
            reasoning: .init(effort: configuration.reasoningEffort),
            instructions: instructions,
            text: .init(format: .init(responseFormat: responseFormat)),
            input: items.map(\.jsonValue),
            tools: responsesTools(
                from: tools,
                enableWebSearch: configuration.enableWebSearch
            ),
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

    private static func responsesTools(
        from tools: [ToolDefinition],
        enableWebSearch: Bool
    ) -> [JSONValue] {
        var responsesTools = tools.map(\.responsesJSONValue)

        if enableWebSearch {
            responsesTools.append(.object(["type": .string("web_search")]))
        }

        return responsesTools
    }

    private static func streamEvents(
        request: URLRequest,
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
                code: "responses_http_status_\(httpResponse.statusCode)",
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

    private static func shouldRetry(
        _ error: Error,
        policy: RequestRetryPolicy
    ) -> Bool {
        if let runtimeError = error as? AgentRuntimeError {
            if runtimeError.code == AgentRuntimeError.unauthorized().code {
                return false
            }
            if let statusCode = httpStatusCode(from: runtimeError.code) {
                return policy.retryableHTTPStatusCodes.contains(statusCode)
            }
            return false
        }

        if let urlError = error as? URLError {
            return policy.retryableURLErrorCodes.contains(urlError.errorCode)
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return policy.retryableURLErrorCodes.contains(nsError.code)
        }

        return false
    }

    private static func httpStatusCode(from errorCode: String) -> Int? {
        let prefix = "responses_http_status_"
        guard errorCode.hasPrefix(prefix) else {
            return nil
        }
        return Int(errorCode.dropFirst(prefix.count))
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
                    .compactMap(\.displayText)
                    .joined()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let images = message.content.compactMap(\.imageAttachment)
                guard !text.isEmpty || !images.isEmpty else {
                    return nil
                }
                return .assistantMessage(
                    AgentMessage(
                        threadID: "",
                        role: .assistant,
                        text: text,
                        images: images
                    )
                )

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
        var segments: [String] = []

        if let primaryText = result.primaryText, !primaryText.isEmpty {
            segments.append(primaryText)
        }

        let imageURLs = result.content.compactMap { content -> URL? in
            guard case let .image(url) = content else {
                return nil
            }
            return url
        }
        if !imageURLs.isEmpty {
            segments.append(
                "Image URLs:\n" + imageURLs.map(\.absoluteString).joined(separator: "\n")
            )
        }

        if !segments.isEmpty {
            return segments.joined(separator: "\n\n")
        }
        if let errorMessage = result.errorMessage, !errorMessage.isEmpty {
            return errorMessage
        }
        return result.success ? "Tool execution completed." : "Tool execution failed."
    }

    private static func toolOutputImages(
        from result: ToolResultEnvelope,
        urlSession: URLSession
    ) async -> [AgentImageAttachment] {
        var attachments: [AgentImageAttachment] = []
        for content in result.content {
            guard case let .image(url) = content else {
                continue
            }
            if let attachment = await imageAttachment(from: url, urlSession: urlSession) {
                attachments.append(attachment)
            }
        }
        return attachments.uniqued()
    }

    private static func imageAttachment(
        from url: URL,
        urlSession: URLSession
    ) async -> AgentImageAttachment? {
        if url.scheme?.lowercased() == "data" {
            let decoded = url.absoluteString.removingPercentEncoding ?? url.absoluteString
            return AgentImageAttachment(dataURLString: decoded)
        }

        if url.isFileURL {
            guard let mimeType = inferredImageMimeType(from: url.pathExtension),
                  let data = try? Data(contentsOf: url),
                  !data.isEmpty
            else {
                return nil
            }
            return AgentImageAttachment(mimeType: mimeType, data: data)
        }

        do {
            let (data, response) = try await urlSession.data(from: url)
            guard !data.isEmpty else {
                return nil
            }

            let mimeType = response.mimeType?.lowercased() ?? inferredImageMimeType(from: url.pathExtension)
            let normalized = mimeType ?? "image/png"
            guard normalized.hasPrefix("image/") else {
                return nil
            }
            return AgentImageAttachment(mimeType: normalized, data: data)
        } catch {
            return nil
        }
    }

    private static func inferredImageMimeType(from pathExtension: String) -> String? {
        switch pathExtension.lowercased() {
        case "png":
            "image/png"
        case "jpg", "jpeg":
            "image/jpeg"
        case "gif":
            "image/gif"
        case "webp":
            "image/webp"
        case "heic":
            "image/heic"
        case "heif":
            "image/heif"
        default:
            nil
        }
    }
}

private struct ResponsesRequestBody: Encodable {
    let model: String
    let reasoning: ResponsesReasoningConfiguration
    let instructions: String
    let text: ResponsesTextConfiguration
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
        case reasoning
        case instructions
        case text
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

private struct ResponsesReasoningConfiguration: Encodable {
    let effort: String

    init(effort: ReasoningEffort) {
        self.effort = effort.apiValue
    }
}

private struct ResponsesTextConfiguration: Encodable {
    let format: ResponsesTextFormat
}

private struct ResponsesTextFormat: Encodable {
    let type: String
    let name: String?
    let description: String?
    let schema: JSONValue?
    let strict: Bool?

    init(responseFormat: AgentStructuredOutputFormat?) {
        if let responseFormat {
            type = "json_schema"
            name = responseFormat.name
            description = responseFormat.description
            schema = responseFormat.schema.jsonValue
            strict = responseFormat.strict
        } else {
            type = "text"
            name = nil
            description = nil
            schema = nil
            strict = nil
        }
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

        var content: [JSONValue] = []

        switch message.role {
        case .assistant:
            if !message.text.isEmpty {
                content.append(.object([
                    "type": .string("output_text"),
                    "text": .string(message.text),
                ]))
            }
            content.append(contentsOf: message.images.map { image in
                .object([
                    "type": .string("output_image"),
                    "image_url": .string(image.dataURLString),
                ])
            })

        default:
            if !message.text.isEmpty {
                content.append(.object([
                    "type": .string("input_text"),
                    "text": .string(message.text),
                ]))
            }

            if message.role == .user {
                content.append(contentsOf: message.images.map { image in
                    .object([
                        "type": .string("input_image"),
                        "image_url": .string(image.dataURLString),
                    ])
                })
            }
        }

        return .object([
            "type": .string("message"),
            "role": .string(roleValue),
            "content": .array(content),
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
    case assistantMessage(AgentMessage)
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
    let displayText: String?
    let imageAttachment: AgentImageAttachment?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let object = try container.decode([String: JSONValue].self)
        type = object["type"]?.stringValue ?? ""
        displayText = object["text"]?.stringValue ?? object["refusal"]?.stringValue
        imageAttachment = Self.parseImageAttachment(from: object)
    }

    private static func parseImageAttachment(from object: [String: JSONValue]) -> AgentImageAttachment? {
        if let dataURL = object["image_url"]?.stringValue,
           let attachment = AgentImageAttachment(dataURLString: dataURL) {
            return attachment
        }

        if let imageObject = object["image"]?.objectValue,
           let dataURL = imageObject["image_url"]?.stringValue,
           let attachment = AgentImageAttachment(dataURLString: dataURL) {
            return attachment
        }

        if let b64 = object["b64_json"]?.stringValue {
            return AgentImageAttachment(base64String: b64)
        }

        return nil
    }
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

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
