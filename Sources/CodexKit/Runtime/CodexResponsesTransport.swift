import Foundation

struct CodexResponsesRequestFactory: Sendable {
    let configuration: CodexResponsesBackendConfiguration
    let encoder: JSONEncoder
    var supportsImageDetailOriginal: Bool? = nil

    func buildURLRequest(
        threadConfiguration: AgentThreadConfiguration,
        instructions: String,
        responseContract: AgentResponseContract?,
        threadID: String,
        items: [WorkingHistoryItem],
        tools: [ToolDefinition],
        session: ChatGPTSession,
        recoveryMode: Bool = false,
        isCompaction: Bool = false,
        webSearch: AgentWebSearchPolicy? = nil
    ) throws -> URLRequest {
        let search = try configuration.webSearchCapabilities.resolve(webSearch)
        return try buildURLRequest(
            model: threadConfiguration.model,
            reasoning: .init(effort: threadConfiguration.reasoningEffort,
                summary: configuration.enableReasoningSummaries ? .auto : nil),
            instructions: instructions,
            text: .init(
                format: .init(
                    responseFormat: responseContract?.textFormat
                )
            ),
            input: items.map(\.jsonValue),
            tools: !recoveryMode && AgentStructuredRecoveryContext.current == nil ? responsesTools(
                from: tools,
                enableWebSearch: !isCompaction && search.mode != .disabled,
                enableImageGeneration: configuration.enableImageGeneration,
                imageGenerationOutputFormat: configuration.imageGenerationOutputFormat,
                webSearchPolicy: search
            ) : [],
            toolChoice: !recoveryMode && AgentStructuredRecoveryContext.current == nil ? .auto : .none,
            parallelToolCalls: tools.contains(where: \.supportsParallelExecution),
            include: [.encryptedReasoning],
            promptCacheKey: threadID,
            requestID: threadID,
            session: session,
            sortedKeys: recoveryMode || AgentStructuredRecoveryContext.current != nil,
            isCompaction: isCompaction
        )
    }

    /// The Codex endpoint uses the same streaming envelope for chat and image requests.
    func buildURLRequest(
        model: String,
        reasoning: ResponsesReasoningConfiguration? = nil,
        instructions: String,
        text: ResponsesTextConfiguration = .init(format: .init(responseFormat: nil)),
        input: [JSONValue],
        tools: [JSONValue],
        toolChoice: ResponsesRequestBody.ToolChoice = .auto,
        parallelToolCalls: Bool = false,
        include: [ResponsesRequestBody.IncludedField] = [],
        promptCacheKey: String? = nil,
        requestID: String,
        session: ChatGPTSession,
        sortedKeys: Bool = false,
        isCompaction: Bool = false
    ) throws -> URLRequest {
        let requestBody = ResponsesRequestBody(
            model: model, reasoning: reasoning, instructions: instructions, text: text,
            input: CodexResponsesImageDetail.normalize(input, supportsOriginal: supportsImageDetailOriginal
                ?? CodexModel(rawValue: model).info?.supportsImageDetailOriginal ?? false),
            tools: tools, toolChoice: toolChoice, parallelToolCalls: parallelToolCalls,
            store: false, stream: true, include: include, promptCacheKey: promptCacheKey
        )

        var request = URLRequest(url: configuration.baseURL.appendingPathComponent("responses"))
        request.httpMethod = HTTPMethod.post.rawValue
        request.timeoutInterval = configuration.streamIdleTimeout
        if sortedKeys {
            let stableEncoder = JSONEncoder()
            stableEncoder.outputFormatting = [.sortedKeys]
            request.httpBody = try stableEncoder.encode(requestBody)
        } else {
            request.httpBody = try encoder.encode(requestBody)
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(session.account.id, forHTTPHeaderField: "ChatGPT-Account-ID")
        request.setValue(requestID, forHTTPHeaderField: "session_id")
        request.setValue(requestID, forHTTPHeaderField: "x-client-request-id")
        request.setValue(configuration.originator, forHTTPHeaderField: "originator")

        for (header, value) in configuration.extraHeaders {
            request.setValue(value, forHTTPHeaderField: header)
        }

        if isCompaction {
            let key = "x-codex-beta-features"
            let features = request.value(forHTTPHeaderField: key).map { $0 + "," } ?? ""
            request.setValue(features + "remote_compaction_v2", forHTTPHeaderField: key)
        }
        return request
    }

    func responsesTools(
        from tools: [ToolDefinition],
        enableWebSearch: Bool,
        enableImageGeneration: Bool,
        imageGenerationOutputFormat: String,
        webSearchPolicy: AgentWebSearchPolicy? = nil
    ) -> [JSONValue] {
        var responsesTools = tools.map(\.responsesJSONValue)
        if enableWebSearch {
            let policy = webSearchPolicy ?? .init(mode: .live)
            var search: [String: JSONValue] = ["type": ResponsesToolType.webSearch.jsonValue,
                "external_web_access": .bool(policy.mode != .cached)]
            if policy.mode == .indexed { search["indexed_web_access"] = .bool(true) }
            if let domains = policy.allowedDomains {
                search["filters"] = .object(["allowed_domains": .array(domains.map(JSONValue.string))])
            }
            responsesTools.append(.object(search))
        }
        if enableImageGeneration {
            responsesTools.append(.object([
                "type": ResponsesToolType.imageGeneration.jsonValue,
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
    var httpErrorPrefix = "responses"

    func streamEvents(
        request: URLRequest
    ) async throws -> AsyncThrowingStream<CodexResponsesStreamEvent, Error> {
        try await openEventStream(request: request).events
    }

    func openEventStream(
        request: URLRequest
    ) async throws -> (events: AsyncThrowingStream<CodexResponsesStreamEvent, Error>, http: AgentHTTPFailure) {
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
        try await AgentStructuredRecoveryContext.current?.beforeTransmission()
        try Task.checkCancellation()
        let (bytes, response) = try await urlSession.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            bytes.task.cancel()
            throw AgentRuntimeError(
                code: .responsesInvalidResponse,
                message: "The ChatGPT responses endpoint returned an invalid response."
            )
        }

        let rateLimits = CodexRateLimitParser.headers(httpResponse)
        if !rateLimits.isEmpty { await rateLimitObserver(rateLimits) }

        if !(200 ..< 300).contains(httpResponse.statusCode) {
            defer { bytes.task.cancel() }
            let bodyData: Data
            do {
                bodyData = try await readAll(bytes, limit: AgentStoreLimits.maximumResponseErrorBodyByteCount)
            } catch let error as AgentRuntimeError {
                throw AgentRuntimeError(code: error.code, message: error.message, http: .init(response: httpResponse))
            }
            try Task.checkCancellation()
            let failure = AgentHTTPFailure(response: httpResponse, body: bodyData)
            logger.error(
                .network,
                "Responses event stream failed with HTTP status.",
                metadata: [
                    "status": "\(httpResponse.statusCode)",
                    "body_length": "\(bodyData.count)",
                    "provider_code": failure.providerCode ?? "",
                    "provider_type": failure.providerType ?? "",
                    "request_id": failure.requestID ?? ""
                ]
            )
            // Keep the provider's explanation, not the entire potentially private error payload.
            let providerError = try? decoder.decode(HTTPProviderError.self, from: bodyData)
            throw AgentRuntimeError.httpFailure(response: httpResponse, body: bodyData, prefix: httpErrorPrefix,
                message: providerError?.message
                    ?? "The ChatGPT responses request failed with status \(httpResponse.statusCode)."
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
                defer { bytes.task.cancel() }
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
                                code: .responsesEventTooLarge,
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
            continuation.onCancellation {
                producerTask.cancel()
                bytes.task.cancel()
            }
        }
        return (events, AgentHTTPFailure(response: httpResponse))
    }

    private struct HTTPProviderError: Decodable {
        let message: String?

        private enum CodingKeys: String, CodingKey { case error, message, detail }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            message = (try? container.decode(StreamErrorPayload.self, forKey: .error))?.message
                ?? (try? container.decode(String.self, forKey: .error))
                ?? (try? container.decode(String.self, forKey: .message))
                ?? (try? container.decode(String.self, forKey: .detail))
        }
    }

    func shouldRetry(
        _ error: Error,
        policy: RequestRetryPolicy
    ) -> Bool {
        if let runtimeError = error as? AgentRuntimeError {
            if runtimeError.http?.isQuotaExceeded == true || runtimeError.knownCode == .quotaExceeded { return false }
            if let code = runtimeError.interruption?.transportErrorCode {
                return policy.retryableURLErrorCodes.contains(code)
            }
            if runtimeError.knownCode == .responsesStreamDisconnected { return true }
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

    func parseStreamEvent(
        from payload: SSEEventPayload
    ) throws -> CodexResponsesStreamEvent? {
        guard !payload.data.isEmpty else {
            return nil
        }
        guard payload.data.utf8.count <= AgentStoreLimits.maximumResponseEventByteCount else {
            throw AgentRuntimeError(
                code: .responsesEventTooLarge,
                message: "A Responses stream event exceeded the supported size limit."
            )
        }

        let payloadData = Data(payload.data.utf8)
        let envelope: CodexResponsesEventPayload
        do {
            envelope = try decoder.decode(
                CodexResponsesEventPayload.self,
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
        let logsResponsePayload = envelope.logsResponsePayload
        let logsPayload = logger.isVerboseEnabled(for: .network)
            || (logsResponsePayload && logger.isEnabled(.debug, for: .network))
        let sanitizedPayload = logsPayload ? sanitizedResponsesJSONString(from: payloadData) : ""
        if logger.isVerboseEnabled(for: .network) {
            logger.verbose(
                .network,
                "Responses stream payload.",
                metadata: ["payload": sanitizedPayload]
            )
        }
        if logsResponsePayload {
            logger.debug(
                .network,
                "Responses response payload.",
                metadata: [
                    "type": envelope.type,
                    "payload": sanitizedPayload
                ]
            )
        }

        return envelope.event
    }

    private func readAll(
        _ bytes: URLSession.AsyncBytes,
        limit: Int
    ) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else {
                throw AgentRuntimeError(
                    code: .responsesErrorBodyTooLarge,
                    message: "The Responses error body exceeded the supported size limit."
                )
            }
            data.append(byte)
        }
        return data
    }
}
