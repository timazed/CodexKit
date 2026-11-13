import Foundation

/// A compaction is committed only after a terminal event and exactly one opaque checkpoint.
struct CodexResponsesCompactionTransport {
    let configuration: CodexResponsesBackendConfiguration
    let urlSession: URLSession
    let decoder: JSONDecoder
    let logger: AgentLogger
    var rateLimitObserver: @Sendable ([AgentRateLimitSnapshot]) async -> Void = { _ in }

    func compact(input: [JSONValue], buildRequest: ([JSONValue]) throws -> URLRequest)
        async throws -> (checkpoint: JSONValue, input: [JSONValue]) {
        var input = input
        var request = try buildRequest(input)
        let client = CodexResponsesEventStreamClient(urlSession: urlSession, decoder: decoder, logger: logger)
        let budget = CodexResponseBudget(maximumBytes: configuration.maximumResponseBytes)
        let policy = configuration.requestRetryPolicy
        let attempts = min(3, policy.maxAttempts)
        for attempt in 1...attempts {
            do {
                let checkpoint = try await collect(request: request, client: client, budget: budget)
                return (checkpoint, input)
            } catch {
                try Task.checkCancellation()
                guard attempt < attempts else { throw error }
                if let failure = (error as? AgentRuntimeError)?.http,
                   failure.providerCode == "context_length_exceeded",
                   let status = HTTPStatusCode(rawValue: failure.statusCode),
                   status == .badRequest || status == .ok {
                    guard let trimmed = trimOldestItem(from: input) else { throw error }
                    input = trimmed
                    request = try buildRequest(input)
                    continue
                }
                guard client.shouldRetry(error, policy: policy) else { throw error }
                let delay = max(policy.delayBeforeRetry(attempt: attempt),
                    (error as? AgentRuntimeError)?.http?.retryAfter ?? 0)
                if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
            }
        }
        preconditionFailure("Compaction attempts must be positive")
    }

    private func trimOldestItem(from input: [JSONValue]) -> [JSONValue]? {
        guard input.count > 1, let oldest = input.first?.objectValue else { return nil }
        let remaining = input.dropFirst()
        let oldestType = ResponsesItemType(wireValue: oldest["type"])
        if oldestType == .message, oldest["role"] == .string(AgentRole.user.rawValue),
           !remaining.contains(where: {
               $0.objectValue?["type"] == ResponsesItemType.message.jsonValue
                   && $0.objectValue?["role"] == .string(AgentRole.user.rawValue)
           }) { return nil }

        let counterparts: [ResponsesItemType]
        switch oldestType {
        case .functionCall, .localShellCall: counterparts = [.functionCallOutput]
        case .functionCallOutput: counterparts = [.functionCall, .localShellCall]
        case .customToolCall: counterparts = [.customToolCallOutput]
        case .customToolCallOutput: counterparts = [.customToolCall]
        case .toolSearchCall: counterparts = [.toolSearchOutput]
        case .toolSearchOutput: counterparts = [.toolSearchCall]
        default: return Array(remaining)
        }
        var trimmed = Array(remaining)
        if let callID = oldest["call_id"]?.stringValue,
           let index = trimmed.firstIndex(where: {
               guard let object = $0.objectValue, let type = ResponsesItemType(wireValue: object["type"]) else { return false }
               return counterparts.contains(type) && object["call_id"] == .string(callID)
           }) {
            trimmed.remove(at: index)
        }
        return trimmed.isEmpty ? nil : trimmed
    }

    private func collect(request: URLRequest, client: CodexResponsesEventStreamClient,
        budget: CodexResponseBudget) async throws -> JSONValue {
        if let body = request.httpBody, logger.isEnabled(.debug, for: .network) {
            logger.debug(.network, "Streamed compaction request payload.",
                metadata: ["payload": sanitizedResponsesJSONString(from: body)])
        }
        let (bytes, response) = try await urlSession.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse else {
            throw AgentRuntimeError(code: .responsesCompactInvalidResponse, message: "Invalid compaction response.")
        }
        await rateLimitObserver(CodexRateLimitParser.headers(response))
        guard (200..<300).contains(response.statusCode) else {
            let limit = min(configuration.maximumResponseBytes ?? Int.max, AgentStoreLimits.maximumResponseErrorBodyByteCount)
            var data = Data()
            if limit > 0 {
                for try await byte in bytes {
                    data.append(byte)
                    if data.count == limit { break }
                }
            }
            throw AgentRuntimeError.httpFailure(response: response, body: data, prefix: "responses_compact",
                message: "The ChatGPT compaction request failed with status \(response.statusCode): \(sanitizedResponsesJSONString(from: data))")
        }
        if let limit = configuration.maximumResponseBytes, response.expectedContentLength > Int64(limit) {
            throw AgentRuntimeError.executionLimitExceeded(.responseBytes)
        }
        var parser = SSEEventParser()
        var line = Data()
        var output: JSONValue?
        var count = 0
        func accept(_ payload: SSEEventPayload) throws -> JSONValue? {
            guard let event = try client.parseStreamEvent(from: payload) else { return nil }
            switch event.kind {
            case let .outputItem(item, _):
                try budget.consumeItem()
                if item.type == .compaction {
                    count += 1
                    output = item.rawValue
                }
            case .completed:
                guard count == 1, let output,
                      let encrypted = output.objectValue?["encrypted_content"]?.stringValue,
                      !encrypted.isEmpty else {
                    throw AgentRuntimeError(code: .responsesCompactInvalidOutput,
                        message: "Streamed compaction requires exactly one nonempty encrypted compaction item.")
                }
                return output
            case let .failed(error, _): throw error
            default: break
            }
            return nil
        }
        // Decode incrementally without publishing partial compaction results.
        for try await byte in bytes {
            try Task.checkCancellation()
            if byte == UInt8(ascii: "\n") {
                try budget.consume(line.count + 1)
                let text = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .newlines)
                line.removeAll(keepingCapacity: true)
                if let payload = try parser.consume(line: text), let output = try accept(payload) { return output }
            } else {
                guard line.count < AgentStoreLimits.maximumResponseEventByteCount else {
                    throw AgentRuntimeError(code: .responsesEventTooLarge, message: "Compaction event exceeded its size limit.")
                }
                line.append(byte)
            }
        }
        try Task.checkCancellation()
        if !line.isEmpty {
            try budget.consume(line.count)
            let text = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .newlines)
            if let payload = try parser.consume(line: text), let output = try accept(payload) { return output }
        }
        if let payload = parser.finish(), let output = try accept(payload) { return output }
        throw AgentRuntimeError(code: .responsesStreamDisconnected,
            message: "Compaction stream closed before response.completed.")
    }
}
