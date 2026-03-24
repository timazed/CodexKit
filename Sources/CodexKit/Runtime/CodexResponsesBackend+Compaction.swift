import Foundation

extension CodexResponsesBackend: AgentBackendContextCompacting {
    public func compactContext(
        thread: AgentThread,
        effectiveHistory: [AgentMessage],
        instructions: String,
        tools: [ToolDefinition],
        session: ChatGPTSession
    ) async throws -> AgentCompactionResult {
        let requestBody = ResponsesCompactRequestBody(
            model: configuration.model,
            reasoning: .init(effort: configuration.reasoningEffort),
            instructions: instructions,
            text: .init(format: .init(responseFormat: nil)),
            input: effectiveHistory.map { WorkingHistoryItem.visibleMessage($0).jsonValue },
            tools: CodexResponsesTurnSession.responsesTools(
                from: tools,
                enableWebSearch: configuration.enableWebSearch
            ),
            parallelToolCalls: false
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

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AgentRuntimeError(
                code: "responses_compact_invalid_response",
                message: "The ChatGPT compact endpoint returned an invalid response."
            )
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AgentRuntimeError(
                code: "responses_compact_failed",
                message: "The ChatGPT compact endpoint failed with status \(httpResponse.statusCode): \(body)"
            )
        }

        let payload = try decoder.decode(JSONValue.self, from: data)
        let output = payload.objectValue?["output"]?.arrayValue ?? []
        let messages = output.compactMap { item in
            Self.compactedMessage(from: item, threadID: thread.id)
        }
        guard !messages.isEmpty else {
            throw AgentRuntimeError.contextCompactionUnsupported()
        }

        return AgentCompactionResult(
            effectiveMessages: messages,
            summaryPreview: messages.first?.displayText
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

        if type == "compaction",
           let summary = object["encrypted_content"]?.stringValue {
            return AgentMessage(
                threadID: threadID,
                role: .system,
                text: summary
            )
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
