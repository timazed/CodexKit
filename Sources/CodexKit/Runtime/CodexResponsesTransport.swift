import Foundation

struct CodexResponsesRequestFactory: Sendable {
    let configuration: CodexResponsesBackendConfiguration
    let encoder: JSONEncoder

    func buildURLRequest(
        instructions: String,
        responseFormat: AgentStructuredOutputFormat?,
        streamedStructuredOutput: AgentStreamedStructuredOutputRequest?,
        threadID: String,
        items: [WorkingHistoryItem],
        tools: [ToolDefinition],
        session: ChatGPTSession
    ) throws -> URLRequest {
        let resolvedInstructions = if let streamedStructuredOutput {
            instructions + "\n\n" + CodexResponsesTurnSession.streamedStructuredOutputInstructions(for: streamedStructuredOutput)
        } else {
            instructions
        }
        let requestBody = ResponsesRequestBody(
            model: configuration.model,
            reasoning: .init(effort: configuration.reasoningEffort),
            instructions: resolvedInstructions,
            text: .init(
                format: .init(
                    responseFormat: streamedStructuredOutput == nil ? responseFormat : nil
                )
            ),
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

    func responsesTools(
        from tools: [ToolDefinition],
        enableWebSearch: Bool
    ) -> [JSONValue] {
        var responsesTools = tools.map(\.responsesJSONValue)
        if enableWebSearch {
            responsesTools.append(.object(["type": .string("web_search")]))
        }
        return responsesTools
    }
}

struct CodexResponsesEventStreamClient: Sendable {
    let urlSession: URLSession
    let decoder: JSONDecoder

    func streamEvents(
        request: URLRequest
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

                            if let payload = parser.consume(line: line),
                               let event = try parseStreamEvent(from: payload) {
                                continuation.yield(event)
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
                        if let payload = parser.consume(line: line),
                           let event = try parseStreamEvent(from: payload) {
                            continuation.yield(event)
                        }
                    }

                    if let payload = parser.finish(),
                       let event = try parseStreamEvent(from: payload) {
                        continuation.yield(event)
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func shouldRetry(
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

    private func httpStatusCode(from errorCode: String) -> Int? {
        let prefix = "responses_http_status_"
        guard errorCode.hasPrefix(prefix) else {
            return nil
        }
        return Int(errorCode.dropFirst(prefix.count))
    }

    private func parseStreamEvent(
        from payload: SSEEventPayload
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

    private func readAll(_ bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
        }
        return data
    }
}

struct CodexResponsesToolOutputAdapter: Sendable {
    let urlSession: URLSession

    func text(from result: ToolResultEnvelope) -> String {
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
            segments.append("Image URLs:\n" + imageURLs.map(\.absoluteString).joined(separator: "\n"))
        }

        if !segments.isEmpty {
            return segments.joined(separator: "\n\n")
        }
        if let errorMessage = result.errorMessage, !errorMessage.isEmpty {
            return errorMessage
        }
        return result.success ? "Tool execution completed." : "Tool execution failed."
    }

    func images(from result: ToolResultEnvelope) async -> [AgentImageAttachment] {
        var attachments: [AgentImageAttachment] = []
        for content in result.content {
            guard case let .image(url) = content else {
                continue
            }
            if let attachment = await imageAttachment(from: url) {
                attachments.append(attachment)
            }
        }
        return attachments.uniqued()
    }

    private func imageAttachment(from url: URL) async -> AgentImageAttachment? {
        if url.scheme?.lowercased() == "data" {
            let decoded = url.absoluteString.removingPercentEncoding ?? url.absoluteString
            return AgentImageAttachment(dataURLString: decoded)
        }

        if url.isFileURL {
            guard let mimeType = RuntimeImageMimeType(pathExtension: url.pathExtension),
                  let data = try? Data(contentsOf: url),
                  !data.isEmpty else {
                return nil
            }
            return AgentImageAttachment(mimeType: mimeType.rawValue, data: data)
        }

        do {
            let (data, response) = try await urlSession.data(from: url)
            guard !data.isEmpty else {
                return nil
            }

            let mimeType = RuntimeImageMimeType(
                responseMimeType: response.mimeType,
                pathExtension: url.pathExtension
            ) ?? .png
            guard mimeType.isImage else {
                return nil
            }
            return AgentImageAttachment(mimeType: mimeType.rawValue, data: data)
        } catch {
            return nil
        }
    }
}

private enum RuntimeImageMimeType: String {
    case png = "image/png"
    case jpeg = "image/jpeg"
    case gif = "image/gif"
    case webp = "image/webp"
    case heic = "image/heic"
    case heif = "image/heif"

    init?(pathExtension: String) {
        switch pathExtension.lowercased() {
        case "png":
            self = .png
        case "jpg", "jpeg":
            self = .jpeg
        case "gif":
            self = .gif
        case "webp":
            self = .webp
        case "heic":
            self = .heic
        case "heif":
            self = .heif
        default:
            return nil
        }
    }

    init?(responseMimeType: String?, pathExtension: String) {
        if let responseMimeType,
           let normalized = Self(rawValue: responseMimeType.lowercased()) {
            self = normalized
            return
        }

        guard let inferred = Self(pathExtension: pathExtension) else {
            return nil
        }

        self = inferred
    }

    var isImage: Bool {
        rawValue.hasPrefix("image/")
    }
}
