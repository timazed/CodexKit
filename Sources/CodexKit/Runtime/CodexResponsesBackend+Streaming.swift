import Foundation

struct SSEEventPayload {
    let event: String?
    let data: String
}

struct SSEEventParser {
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

struct StreamEnvelope: Decodable {
    let type: String
    let delta: String?
    let item: StreamItem?
    let response: StreamResponsePayload?
}

enum StreamItem: Decodable {
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

struct StreamMessageItem: Decodable {
    let role: String
    let content: [StreamMessageContent]
}

struct StreamMessageContent: Decodable {
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

struct StreamFunctionCallItem: Decodable {
    let name: String
    let arguments: String
    let callID: String

    enum CodingKeys: String, CodingKey {
        case name
        case arguments
        case callID = "call_id"
    }
}

struct StreamResponsePayload: Decodable {
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

struct StreamUsage: Decodable {
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

struct StreamInputTokenDetails: Decodable {
    let cachedTokens: Int

    enum CodingKeys: String, CodingKey {
        case cachedTokens = "cached_tokens"
    }
}

struct StreamErrorPayload: Decodable {
    let message: String?
}

struct StreamIncompleteDetails: Decodable {
    let reason: String?
}

extension CodexResponsesTurnSession {
    static func buildURLRequest(
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

    static func responsesTools(
        from tools: [ToolDefinition],
        enableWebSearch: Bool
    ) -> [JSONValue] {
        var responsesTools = tools.map(\.responsesJSONValue)

        if enableWebSearch {
            responsesTools.append(.object(["type": .string("web_search")]))
        }

        return responsesTools
    }

    static func streamEvents(
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

    static func shouldRetry(
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

    static func httpStatusCode(from errorCode: String) -> Int? {
        let prefix = "responses_http_status_"
        guard errorCode.hasPrefix(prefix) else {
            return nil
        }
        return Int(errorCode.dropFirst(prefix.count))
    }

    static func parseStreamEvent(
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

    static func readAll(_ bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
        }
        return data
    }

    static func toolOutputText(from result: ToolResultEnvelope) -> String {
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

    static func toolOutputImages(
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

    static func imageAttachment(
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

    static func inferredImageMimeType(from pathExtension: String) -> String? {
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
