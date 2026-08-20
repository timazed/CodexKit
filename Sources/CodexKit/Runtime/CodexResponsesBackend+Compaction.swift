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
            items
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

        if let bodyData = request.httpBody {
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

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AgentRuntimeError(
                code: "responses_compact_invalid_response",
                message: "The ChatGPT compact endpoint returned an invalid response."
            )
        }
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
            throw AgentRuntimeError(
                code: "responses_compact_failed",
                message: "The ChatGPT compact endpoint failed with status \(httpResponse.statusCode): \(body)"
            )
        }

        logger.debug(
            .network,
            "Responses compact response payload.",
            metadata: [
                "thread_id": thread.id,
                "status": "\(httpResponse.statusCode)",
                "payload": sanitizedResponsesJSONString(from: data)
            ]
        )

        let payload = try decoder.decode(JSONValue.self, from: data)
        let output = payload.objectValue?["output"]?.arrayValue ?? []
        let messages = output.compactMap { item in
            Self.compactedMessage(from: item, threadID: thread.id)
        }
        guard !output.isEmpty else {
            throw AgentRuntimeError.contextCompactionUnsupported()
        }

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
            providerContext: CodexResponsesProviderState(items: output).agentProviderContext,
            summaryPreview: nil
        )
    }

    private static func compactedMessage(
        from value: JSONValue,
        threadID: String
    ) -> AgentMessage? {
        guard let object = value.objectValue,
              let type = object["type"]?.stringValue
        else {
            return nil
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

        let text = (object["content"]?.arrayValue ?? []).compactMap { item -> String? in
            guard let content = item.objectValue else {
                return nil
            }
            return content["text"]?.stringValue
        }.joined(separator: "\n")

        return AgentMessage(
            threadID: threadID,
            role: role,
            text: text
        )
    }
}

extension CodexResponsesBackend: AgentBackendProviderContextCompacting {}
