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
        let completionCapture = AgentTurnCompletionCapture()
        let stream = try await streamRequest(
            request,
            in: threadID,
            responseContract: nil,
            completionCapture: completionCapture
        )
        let completed = try await collectFinalAssistantTurn(from: stream)
        let memoryApplication = await completionCapture.memoryApplication()
        return AgentTurnResult(
            value: completed.message.displayText,
            summary: completed.summary,
            clientRequestID: request.clientRequestID,
            memoryApplication: memoryApplication
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
        let capture = AgentOneShotResponseCapture<Output>(format: responseContract.format, decoder: decoder)
        let stream = try await streamRequest(request, in: threadID, responseContract: responseContract,
            oneShotValidation: .init(format: responseContract.format, validate: { try await capture.validate($0) }))
        _ = try await collectFinalAssistantMessage(from: stream)
        return try await capture.value()
    }

    func sendWithSummary<Output: Decodable & Sendable>(
        _ request: Request,
        in threadID: String,
        response outputType: Output.Type,
        responseContract: AgentResponseContract,
        decoder: JSONDecoder = JSONDecoder()
    ) async throws -> AgentTurnResult<Output> {
        let capture = AgentOneShotResponseCapture<Output>(format: responseContract.format, decoder: decoder)
        let completionCapture = AgentTurnCompletionCapture()
        let stream = try await streamRequest(request, in: threadID, responseContract: responseContract,
            completionCapture: completionCapture,
            oneShotValidation: .init(format: responseContract.format, validate: { try await capture.validate($0) }))
        let completed = try await collectFinalAssistantTurn(from: stream)
        let memoryApplication = await completionCapture.memoryApplication()
        return AgentTurnResult(
            value: try await capture.value(),
            summary: completed.summary,
            clientRequestID: request.clientRequestID,
            memoryApplication: memoryApplication
        )
    }
}
