import Foundation

/// A compaction is committed only after a terminal event and exactly one opaque checkpoint.
struct CodexResponsesCompactionTransport {
    let configuration: CodexResponsesBackendConfiguration
    let urlSession: URLSession
    let decoder: JSONDecoder
    let logger: AgentLogger
    var rateLimitObserver: @Sendable ([AgentRateLimitSnapshot]) async -> Void = { _ in }

    func compact(request: URLRequest) async throws -> JSONValue {
        if let body = request.httpBody, logger.isEnabled(.debug, for: .network) {
            logger.debug(.network, "Streamed compaction request payload.",
                metadata: ["payload": sanitizedResponsesJSONString(from: body)])
        }
        let client = CodexResponsesEventStreamClient(urlSession: urlSession, decoder: decoder, logger: logger)
        let budget = CodexResponseBudget(maximumBytes: configuration.maximumResponseBytes)
        let policy = configuration.requestRetryPolicy
        // Like upstream, allow at most two stream retries for compaction.
        let attempts = min(3, policy.maxAttempts)
        for attempt in 1...attempts {
            do { return try await collect(request: request, client: client, budget: budget) }
            catch {
                try Task.checkCancellation()
                guard attempt < attempts, client.shouldRetry(error, policy: policy) else { throw error }
                let delay = max(policy.delayBeforeRetry(attempt: attempt),
                    (error as? AgentRuntimeError)?.http?.retryAfter ?? 0)
                if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
            }
        }
        preconditionFailure("Compaction attempts must be positive")
    }

    private func collect(request: URLRequest, client: CodexResponsesEventStreamClient,
        budget: CodexResponseBudget) async throws -> JSONValue {
        let (bytes, response) = try await urlSession.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse else {
            throw AgentRuntimeError(code: "responses_compact_invalid_response", message: "Invalid compaction response.")
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
                if item.rawValue.objectValue?["type"] == .string("compaction") {
                    count += 1
                    output = item.rawValue
                }
            case .completed:
                guard count == 1, let output,
                      let encrypted = output.objectValue?["encrypted_content"]?.stringValue,
                      !encrypted.isEmpty else {
                    throw AgentRuntimeError(code: "responses_compact_invalid_output",
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
                    throw AgentRuntimeError(code: "responses_event_too_large", message: "Compaction event exceeded its size limit.")
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
        throw AgentRuntimeError(code: "responses_stream_disconnected",
            message: "Compaction stream closed before response.completed.")
    }
}
