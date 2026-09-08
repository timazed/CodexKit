import Foundation

extension CodexResponsesBackend: AgentBackendContextCompacting {
    public func compactContext(
        thread: AgentThread,
        effectiveHistory: [AgentMessage],
        instructions: String,
        tools: [ToolDefinition],
        session: ChatGPTSession
    ) async throws -> AgentCompactionResult {
        try await compactContext(
            thread: thread,
            effectiveHistory: effectiveHistory,
            providerContext: nil,
            instructions: instructions,
            tools: tools,
            session: session
        )
    }

    public func compactContext(
        thread: AgentThread,
        effectiveHistory: [AgentMessage],
        providerContext: AgentProviderContext?,
        instructions: String,
        tools: [ToolDefinition],
        session: ChatGPTSession
    ) async throws -> AgentCompactionResult {
        try Task.checkCancellation()
        logger.info(
            .compaction,
            "Starting remote context compaction.",
            metadata: [
                "thread_id": thread.id,
                "history_count": "\(effectiveHistory.count)"
            ]
        )
        let requestFactory = CodexResponsesRequestFactory(
            configuration: configuration,
            encoder: encoder
        )
        let threadConfiguration = thread.configuration ?? configuration.defaultThreadConfiguration
        let providerState = CodexResponsesProviderState(context: providerContext)
        let previousResponseID = configuration.stateManagement == .serverManaged
            ? providerState?.previousResponseID
            : nil
        let input: [JSONValue]? = if previousResponseID != nil {
            nil
        } else if let items = providerState?.items, !items.isEmpty {
            try CodexResponsesImageReferences.restore(items,
                using: CodexResponsesImageReferences.attachments(in: effectiveHistory))
        } else {
            effectiveHistory.map { WorkingHistoryItem.visibleMessage($0).jsonValue }
        }
        let requestBody = ResponsesCompactRequestBody(
            model: threadConfiguration.model,
            reasoning: .init(effort: threadConfiguration.reasoningEffort),
            instructions: instructions,
            text: .init(format: .init(responseFormat: nil)),
            input: input,
            tools: requestFactory.responsesTools(
                from: tools,
                enableWebSearch: configuration.enableWebSearch,
                enableImageGeneration: configuration.enableImageGeneration,
                imageGenerationOutputFormat: configuration.imageGenerationOutputFormat
            ),
            parallelToolCalls: false,
            previousResponseID: previousResponseID
        )

        var request = URLRequest(url: configuration.baseURL.appendingPathComponent("responses/compact"))
        request.timeoutInterval = configuration.streamIdleTimeout
        request.httpMethod = "POST"
        request.httpBody = try encoder.encode(requestBody)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(session.account.id, forHTTPHeaderField: "ChatGPT-Account-ID")
        request.setValue(thread.id, forHTTPHeaderField: "session_id")
        request.setValue(thread.id, forHTTPHeaderField: "x-client-request-id")
        request.setValue(configuration.originator, forHTTPHeaderField: "originator")

        for (header, value) in configuration.extraHeaders {
            request.setValue(value, forHTTPHeaderField: header)
        }

        if logger.isEnabled(.debug, for: .network), let bodyData = request.httpBody {
            logger.debug(
                .network,
                "Responses compact request payload.",
                metadata: [
                    "thread_id": thread.id,
                    "request_id": thread.id,
                    "payload": sanitizedResponsesJSONString(from: bodyData)
                ]
            )
        }

        let (data, httpResponse) = try await readCompactionResponse(for: request)
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            let body = sanitizedResponsesJSONString(from: data)
            logger.error(
                .network,
                "Remote context compaction failed.",
                metadata: [
                    "thread_id": thread.id,
                    "status": "\(httpResponse.statusCode)",
                    "body_length": "\(data.count)",
                    "body": body
                ]
            )
            throw AgentRuntimeError.httpFailure(
                response: httpResponse, body: data, prefix: "responses_compact",
                message: "The ChatGPT compact endpoint failed with status \(httpResponse.statusCode): \(body)"
            )
        }

        if logger.isEnabled(.debug, for: .network) {
            logger.debug(
                .network,
                "Responses compact response payload.",
                metadata: [
                    "thread_id": thread.id,
                    "status": "\(httpResponse.statusCode)",
                    "payload": sanitizedResponsesJSONString(from: data)
                ]
            )
        }

        let payload = try decoder.decode(JSONValue.self, from: data)
        let output = payload.objectValue?["output"]?.arrayValue ?? []
        let messages = try output.compactMap { item in
            try Self.compactedMessage(from: item, threadID: thread.id)
        }
        guard !output.isEmpty else {
            throw AgentRuntimeError.contextCompactionUnsupported()
        }
        let storedOutput = try CodexResponsesImageReferences.externalize(output)
        // Every stored reference must have an attachment retained by the compacted
        // context, including after database reopening or transcript pruning.
        try CodexResponsesImageReferences.validate(storedOutput,
            using: CodexResponsesImageReferences.attachments(in: messages))

        logger.info(
            .compaction,
            "Remote context compaction completed.",
            metadata: [
                "thread_id": thread.id,
                "message_count_before": "\(effectiveHistory.count)",
                "message_count_after": "\(messages.count)"
            ]
        )

        return AgentCompactionResult(
            effectiveMessages: messages,
            providerContext: CodexResponsesProviderState(items: storedOutput).agentProviderContext,
            summaryPreview: nil
        )
    }

    private func readCompactionResponse(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await urlSession.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse else {
            throw AgentRuntimeError(code: "responses_compact_invalid_response",
                message: "The ChatGPT compact endpoint returned an invalid response.")
        }
        let isSuccess = (200 ..< 300).contains(response.statusCode)
        let limit = isSuccess ? configuration.maximumResponseBytes
            : min(configuration.maximumResponseBytes ?? Int.max, AgentStoreLimits.maximumResponseErrorBodyByteCount)
        if isSuccess, let limit, response.expectedContentLength > Int64(limit) {
            throw AgentRuntimeError.executionLimitExceeded(.responseBytes)
        }
        var data = Data()
        if !isSuccess, limit == 0 { return (data, response) }
        // AsyncBytes yields individual bytes. Batch Data mutations so large image
        // responses do not pay Foundation's append overhead for every byte.
        var chunk: [UInt8] = []
        chunk.reserveCapacity(65_536)
        var byteCount = 0
        for try await byte in bytes {
            if chunk.isEmpty { try Task.checkCancellation() }
            if let limit, byteCount >= limit {
                if isSuccess { throw AgentRuntimeError.executionLimitExceeded(.responseBytes) }
                break // Preserve HTTP status for authentication recovery, even with an oversized error body.
            }
            chunk.append(byte)
            byteCount += 1
            if chunk.count == 65_536 {
                data.append(contentsOf: chunk)
                chunk.removeAll(keepingCapacity: true)
            }
            if !isSuccess, byteCount == limit { break }
        }
        data.append(contentsOf: chunk)
        try Task.checkCancellation()
        return (data, response)
    }

    private static func compactedMessage(
        from value: JSONValue,
        threadID: String
    ) throws -> AgentMessage? {
        guard let object = value.objectValue,
              let type = object["type"]?.stringValue
        else {
            return nil
        }

        if type == "image_generation_call" {
            let generated = try JSONDecoder().decode(StreamImageGenerationCallItem.self, from: JSONEncoder().encode(value))
            guard let image = generated.imageAttachment else { return nil }
            return AgentMessage(threadID: threadID, role: .assistant, text: generated.assistantText, images: [image])
        }
        guard type == "message",
              let roleRaw = object["role"]?.stringValue
        else {
            return nil
        }

        let role: AgentRole
        switch roleRaw {
        case "assistant":
            role = .assistant
        case "system", "developer":
            role = .system
        case "user":
            role = .user
        default:
            return nil
        }

        let content = object["content"]?.arrayValue ?? []
        let text = content.compactMap { item -> String? in
            guard let content = item.objectValue else {
                return nil
            }
            return content["text"]?.stringValue
        }.joined(separator: "\n")

        return AgentMessage(
            threadID: threadID,
            role: role,
            text: text,
            images: content.compactMap { $0.objectValue.flatMap(StreamMessageContent.parseImageAttachment) },
            phase: object["phase"]?.stringValue.map(AgentMessagePhase.init(rawValue:))
        )
    }
}

extension CodexResponsesBackend: AgentBackendProviderContextCompacting {}
