import Foundation

struct CodexResponsesRequestFactory: Sendable {
    let configuration: CodexResponsesBackendConfiguration
    let encoder: JSONEncoder

    func buildURLRequest(
        threadConfiguration: AgentThreadConfiguration,
        instructions: String,
        responseContract: AgentResponseContract?,
        threadID: String,
        items: [WorkingHistoryItem],
        previousResponseID: String? = nil,
        tools: [ToolDefinition],
        session: ChatGPTSession
    ) throws -> URLRequest {
        let requestBody = ResponsesRequestBody(
            model: threadConfiguration.model,
            reasoning: .init(effort: threadConfiguration.reasoningEffort),
            instructions: instructions,
            text: .init(
                format: .init(
                    responseFormat: responseContract?.textFormat
                )
            ),
            input: items.map(\.jsonValue),
            tools: responsesTools(
                from: tools,
                enableWebSearch: configuration.enableWebSearch,
                enableImageGeneration: configuration.enableImageGeneration,
                imageGenerationOutputFormat: configuration.imageGenerationOutputFormat
            ),
            toolChoice: "auto",
            parallelToolCalls: false,
            store: configuration.stateManagement == .serverManaged,
            stream: true,
            include: configuration.stateManagement == .clientManaged
                ? ["reasoning.encrypted_content"]
                : [],
            previousResponseID: configuration.stateManagement == .serverManaged
                ? previousResponseID
                : nil,
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
        enableWebSearch: Bool,
        enableImageGeneration: Bool,
        imageGenerationOutputFormat: String
    ) -> [JSONValue] {
        var responsesTools = tools.map(\.responsesJSONValue)
        if enableWebSearch {
            responsesTools.append(.object(["type": .string("web_search")]))
        }
        if enableImageGeneration {
            responsesTools.append(.object([
                "type": .string("image_generation"),
                "output_format": .string(imageGenerationOutputFormat),
            ]))
        }
        return responsesTools
    }
}

struct CodexResponsesEventStreamClient: Sendable {
    let urlSession: URLSession
    let decoder: JSONDecoder
    let logger: AgentLogger

    func streamEvents(
        request: URLRequest
    ) async throws -> AsyncThrowingStream<CodexResponsesStreamEvent, Error> {
        if let bodyData = request.httpBody {
            logger.debug(
                .network,
                "Responses request payload.",
                metadata: [
                    "request_id": request.value(forHTTPHeaderField: "x-client-request-id") ?? "",
                    "payload": sanitizedResponsesJSONString(from: bodyData)
                ]
            )
        }
        logger.debug(
            .network,
            "Opening responses event stream.",
            metadata: [
                "url": request.url?.absoluteString ?? "unknown",
                "method": request.httpMethod ?? "POST",
                "request_id": request.value(forHTTPHeaderField: "x-client-request-id") ?? "",
                "session_id": request.value(forHTTPHeaderField: "session_id") ?? "",
                "body_length": "\(request.httpBody?.count ?? 0)"
            ]
        )
        let (bytes, response) = try await urlSession.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AgentRuntimeError(
                code: "responses_invalid_response",
                message: "The ChatGPT responses endpoint returned an invalid response."
            )
        }

        if !(200 ..< 300).contains(httpResponse.statusCode) {
            let bodyData = try await readAll(
                bytes,
                limit: AgentStoreLimits.maximumResponseErrorBodyByteCount
            )
            let body = sanitizedResponsesJSONString(from: bodyData)
            logger.error(
                .network,
                "Responses event stream failed with HTTP status.",
                metadata: [
                    "status": "\(httpResponse.statusCode)",
                    "body_length": "\(bodyData.count)",
                    "body": body
                ]
            )
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw AgentRuntimeError.unauthorized(body)
            }
            throw AgentRuntimeError(
                code: "responses_http_status_\(httpResponse.statusCode)",
                message: "The ChatGPT responses request failed with status \(httpResponse.statusCode): \(body)"
            )
        }

        logger.debug(
            .network,
            "Responses event stream opened.",
            metadata: [
                "status": "\(httpResponse.statusCode)",
                "request_id": request.value(forHTTPHeaderField: "x-client-request-id") ?? "",
                "session_id": request.value(forHTTPHeaderField: "session_id") ?? ""
            ]
        )

        return AsyncThrowingStream { continuation in
            let producerTask = Task {
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

                            if let payload = try parser.consume(line: line),
                               let event = try parseStreamEvent(from: payload) {
                                continuation.yield(event)
                            }
                            continue
                        }

                        guard lineBuffer.count < AgentStoreLimits.maximumResponseEventByteCount else {
                            throw AgentRuntimeError(
                                code: "responses_event_too_large",
                                message: "A Responses stream event exceeded the supported size limit."
                            )
                        }
                        lineBuffer.append(byte)
                    }

                    try Task.checkCancellation()
                    if !lineBuffer.isEmpty {
                        var line = String(decoding: lineBuffer, as: UTF8.self)
                        if line.hasSuffix("\r") {
                            line.removeLast()
                        }
                        if let payload = try parser.consume(line: line),
                           let event = try parseStreamEvent(from: payload) {
                            continuation.yield(event)
                        }
                    }

                    if let payload = parser.finish(),
                       let event = try parseStreamEvent(from: payload) {
                        continuation.yield(event)
                    }

                    logger.debug(
                        .network,
                        "Responses event stream finished.",
                        metadata: [
                            "request_id": request.value(forHTTPHeaderField: "x-client-request-id") ?? "",
                            "session_id": request.value(forHTTPHeaderField: "session_id") ?? ""
                        ]
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
                let shouldRetry = policy.retryableHTTPStatusCodes.contains(statusCode)
                logger.debug(
                    .retry,
                    "Evaluated HTTP retry decision.",
                    metadata: [
                        "status": "\(statusCode)",
                        "retry": "\(shouldRetry)"
                    ]
                )
                return shouldRetry
            }
            return false
        }

        if let retryableURLCode = retryableURLErrorCode(in: error, policy: policy) {
            logger.debug(
                .retry,
                "Evaluated URL error retry decision.",
                metadata: [
                    "code": "\(retryableURLCode)",
                    "retry": "true"
                ]
            )
            return true
        }

        return false
    }

    private func retryableURLErrorCode(
        in error: Error,
        policy: RequestRetryPolicy,
        remainingDepth: Int = 4
    ) -> Int? {
        guard remainingDepth >= 0 else {
            return nil
        }

        if let urlError = error as? URLError,
           policy.retryableURLErrorCodes.contains(urlError.errorCode) {
            return urlError.errorCode
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain,
           policy.retryableURLErrorCodes.contains(nsError.code) {
            return nsError.code
        }

        for value in nsError.userInfo.values {
            guard let nestedError = value as? Error,
                  let retryableCode = retryableURLErrorCode(
                    in: nestedError,
                    policy: policy,
                    remainingDepth: remainingDepth - 1
                  )
            else {
                continue
            }
            return retryableCode
        }

        return nil
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
        guard payload.data.utf8.count <= AgentStoreLimits.maximumResponseEventByteCount else {
            throw AgentRuntimeError(
                code: "responses_event_too_large",
                message: "A Responses stream event exceeded the supported size limit."
            )
        }

        let payloadData = Data(payload.data.utf8)
        let envelope: StreamEnvelope
        do {
            envelope = try decoder.decode(
                StreamEnvelope.self,
                from: payloadData
            )
        } catch {
            logger.error(
                .network,
                "Failed to decode responses stream payload.",
                metadata: [
                    "error": error.localizedDescription,
                    "payload_length": "\(payloadData.count)"
                ]
            )
            throw error
        }
        let sanitizedPayload = sanitizedResponsesJSONString(from: payloadData)
        if logger.isVerboseEnabled(for: .network) {
            logger.verbose(
                .network,
                "Responses stream payload.",
                metadata: ["payload": sanitizedPayload]
            )
        }
        if shouldLogResponsePayload(for: envelope.type) {
            logger.debug(
                .network,
                "Responses response payload.",
                metadata: [
                    "type": envelope.type,
                    "payload": sanitizedPayload
                ]
            )
        }

        let kind: CodexResponsesStreamEvent.Kind
        switch envelope.type {
        case "response.created":
            kind = .responseCreated(responseID: envelope.response?.id)
        case "response.output_text.delta":
            guard let delta = envelope.delta else {
                kind = .other
                break
            }
            kind = .assistantTextDelta(delta)
        case "response.output_item.done":
            guard let item = envelope.item else {
                kind = .other
                break
            }
            kind = .outputItem(
                item,
                outputIndex: envelope.outputIndex ?? 0
            )
        case "response.completed":
            let usage = envelope.response?.usage?.assistantUsage ?? AgentUsage()
            kind = .completed(usage, responseID: envelope.response?.id)
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
            kind = .other
        }
        return CodexResponsesStreamEvent(
            kind: kind,
            sequenceNumber: envelope.sequenceNumber
        )
    }

    private func shouldLogResponsePayload(
        for eventType: String
    ) -> Bool {
        switch eventType {
        case "response.output_item.done",
             "response.completed",
             "response.failed",
             "response.incomplete":
            true
        default:
            false
        }
    }

    private func readAll(
        _ bytes: URLSession.AsyncBytes,
        limit: Int
    ) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else {
                throw AgentRuntimeError(
                    code: "responses_error_body_too_large",
                    message: "The Responses error body exceeded the supported size limit."
                )
            }
            data.append(byte)
        }
        return data
    }
}
