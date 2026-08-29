import Foundation

extension AgentRuntime {
    public func send(
        _ request: Request,
        in threadID: String
    ) async throws -> String {
        let stream = try await streamRequest(
            request,
            in: threadID,
            responseContract: nil
        )
        let message = try await collectFinalAssistantMessage(from: stream)
        return message.displayText
    }

    public func sendWithSummary(
        _ request: Request,
        in threadID: String
    ) async throws -> AgentTurnResult<String> {
        let stream = try await streamRequest(
            request,
            in: threadID,
            responseContract: nil
        )
        let completed = try await collectFinalAssistantTurn(from: stream)
        return AgentTurnResult(
            value: completed.message.displayText,
            summary: completed.summary
        )
    }

    public func send<Output: AgentStructuredOutput>(
        _ request: Request,
        in threadID: String,
        response outputType: Output.Type = Output.self,
        decoder: JSONDecoder = JSONDecoder()
    ) async throws -> Output {
        try await send(
            request,
            in: threadID,
            response: outputType,
            responseContract: AgentResponseContract(
                format: outputType.responseFormat,
                deliveryMode: .oneShot
            ),
            decoder: decoder
        )
    }

    public func sendWithSummary<Output: AgentStructuredOutput>(
        _ request: Request,
        in threadID: String,
        response outputType: Output.Type = Output.self,
        decoder: JSONDecoder = JSONDecoder()
    ) async throws -> AgentTurnResult<Output> {
        try await sendWithSummary(
            request,
            in: threadID,
            response: outputType,
            responseContract: AgentResponseContract(
                format: outputType.responseFormat,
                deliveryMode: .oneShot
            ),
            decoder: decoder
        )
    }

    func send<Output: Decodable & Sendable>(
        _ request: Request,
        in threadID: String,
        response outputType: Output.Type,
        responseContract: AgentResponseContract,
        decoder: JSONDecoder = JSONDecoder()
    ) async throws -> Output {
        let stream = try await streamRequest(
            request,
            in: threadID,
            responseContract: responseContract
        )
        let message = try await collectFinalAssistantMessage(from: stream)
        return try decodeOneShotResponse(
            message.text,
            as: outputType,
            decoder: decoder
        )
    }

    func sendWithSummary<Output: Decodable & Sendable>(
        _ request: Request,
        in threadID: String,
        response outputType: Output.Type,
        responseContract: AgentResponseContract,
        decoder: JSONDecoder = JSONDecoder()
    ) async throws -> AgentTurnResult<Output> {
        let stream = try await streamRequest(
            request,
            in: threadID,
            responseContract: responseContract
        )
        let completed = try await collectFinalAssistantTurn(from: stream)
        return AgentTurnResult(
            value: try decodeOneShotResponse(
                completed.message.text,
                as: outputType,
                decoder: decoder
            ),
            summary: completed.summary
        )
    }

    private func decodeOneShotResponse<Output: Decodable & Sendable>(
        _ text: String,
        as outputType: Output.Type,
        decoder: JSONDecoder
    ) throws -> Output {
        let payload = Data(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        do {
            return try decoder.decode(outputType, from: payload)
        } catch {
            throw AgentRuntimeError.structuredOutputDecodingFailed(
                typeName: String(describing: outputType),
                underlyingMessage: error.localizedDescription
            )
        }
    }
}
