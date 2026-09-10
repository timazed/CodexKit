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
        tools: [ToolDefinition],
        session: ChatGPTSession
    ) throws -> URLRequest {
        let requestBody = ResponsesRequestBody(
            model: threadConfiguration.model,
            reasoning: .init(effort: threadConfiguration.reasoningEffort,
                summary: configuration.enableReasoningSummaries ? "auto" : nil),
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
            parallelToolCalls: tools.contains(where: \.supportsParallelExecution),
            store: false,
            stream: true,
            include: ["reasoning.encrypted_content"],
            promptCacheKey: threadID
        )

        var request = URLRequest(url: configuration.baseURL.appendingPathComponent("responses"))
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.streamIdleTimeout
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
    var maximumBufferedEvents = 64
    var responseBudget: CodexResponseBudget?
    var rateLimitObserver: @Sendable ([AgentRateLimitSnapshot]) async -> Void = { _ in }

    func streamEvents(
        request: URLRequest
    ) async throws -> AsyncThrowingStream<CodexResponsesStreamEvent, Error> {
        if let bodyData = request.httpBody, logger.isEnabled(.debug, for: .network) {
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

        let rateLimits = CodexRateLimitParser.headers(httpResponse)
        if !rateLimits.isEmpty { await rateLimitObserver(rateLimits) }

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
            throw AgentRuntimeError.httpFailure(response: httpResponse, body: bodyData, prefix: "responses",
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

        let (events, continuation) = AgentEventChannel<CodexResponsesStreamEvent>.makeStream(capacity: maximumBufferedEvents)
        do {
            let producerTask = Task {
                var parser = SSEEventParser()

                do {
                    if !rateLimits.isEmpty {
                        try await continuation.yield(.init(kind: .rateLimits(rateLimits), sequenceNumber: nil))
                    }
                    var lineBuffer = Data()

                    for try await byte in bytes {
                        if byte == UInt8(ascii: "\n") {
                            try responseBudget?.consume(lineBuffer.count + 1)
                            var line = String(decoding: lineBuffer, as: UTF8.self)
                            if line.hasSuffix("\r") {
                                line.removeLast()
                            }
                            lineBuffer.removeAll(keepingCapacity: true)

                            if let payload = try parser.consume(line: line),
                               let event = try parseStreamEvent(from: payload) {
                                try await continuation.yield(event)
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
                        try responseBudget?.consume(lineBuffer.count)
                        var line = String(decoding: lineBuffer, as: UTF8.self)
                        if line.hasSuffix("\r") {
                            line.removeLast()
                        }
                        if let payload = try parser.consume(line: line),
                           let event = try parseStreamEvent(from: payload) {
                            try await continuation.yield(event)
                        }
                    }

                    if let payload = parser.finish(),
                       let event = try parseStreamEvent(from: payload) {
                        try await continuation.yield(event)
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
            continuation.onCancellation { producerTask.cancel() }
        }
        return events
    }

    func shouldRetry(
        _ error: Error,
        policy: RequestRetryPolicy
    ) -> Bool {
        if let runtimeError = error as? AgentRuntimeError {
            if runtimeError.code == "responses_stream_disconnected" { return true }
            if runtimeError.code == AgentRuntimeError.unauthorized().code {
                return false
            }
            if let statusCode = runtimeError.http?.statusCode ?? httpStatusCode(from: runtimeError.code) {
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
        if let snapshot = CodexRateLimitParser.event(payloadData) {
            return CodexResponsesStreamEvent(kind: .rateLimits([snapshot]), sequenceNumber: nil)
        }
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
        let logsPayload = logger.isVerboseEnabled(for: .network)
            || (shouldLogResponsePayload(for: envelope.type) && logger.isEnabled(.debug, for: .network))
        let sanitizedPayload = logsPayload ? sanitizedResponsesJSONString(from: payloadData) : ""
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
        case "response.output_item.added":
            guard let object = envelope.item?.rawValue.objectValue,
                  let id = object["id"]?.stringValue else { kind = .other; break }
            if object["type"]?.stringValue == "message" {
                kind = .progress(.messageStarted(itemID: id,
                    phase: object["phase"]?.stringValue.map(AgentMessagePhase.init(rawValue:))))
            } else if object["type"]?.stringValue == "web_search_call" {
                kind = .progress(.webSearch(itemID: id,
                    status: object["status"]?.stringValue ?? "in_progress", action: object["action"]))
            } else { kind = .other }
        case "response.reasoning_summary_text.delta":
            guard let id = envelope.itemID, let delta = envelope.delta else { kind = .other; break }
            kind = .progress(.reasoningSummaryDelta(itemID: id,
                summaryIndex: envelope.summaryIndex ?? 0, delta: delta))
        case "response.web_search_call.in_progress", "response.web_search_call.searching",
             "response.web_search_call.completed":
            guard let id = envelope.itemID else { kind = .other; break }
            kind = .progress(.webSearch(itemID: id,
                status: String(envelope.type.split(separator: ".").last ?? ""), action: nil))
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
            throw AgentRuntimeError(code: "responses_stream_failed", message: message,
                http: .init(statusCode: 200, providerCode: envelope.response?.error?.code,
                    providerType: envelope.response?.error?.type))
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
