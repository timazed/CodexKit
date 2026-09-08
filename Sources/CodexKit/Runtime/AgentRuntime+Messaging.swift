import Foundation

extension AgentRuntime {
    // MARK: - Messaging

    public func stream(
        _ request: Request,
        in threadID: String
    ) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        try await streamRequest(
            request,
            in: threadID,
            responseContract: nil
        )
    }

    public func stream<Output: AgentStructuredOutput>(
        _ request: Request,
        in threadID: String,
        response outputType: Output.Type = Output.self,
        options: AgentStructuredStreamingOptions = AgentStructuredStreamingOptions(),
        decoder: JSONDecoder = JSONDecoder()
    ) async throws -> AsyncThrowingStream<AgentStructuredStreamEvent<Output>, Error> {
        try await stream(
            request,
            in: threadID,
            response: outputType,
            responseContract: AgentResponseContract(
                format: outputType.responseFormat,
                deliveryMode: .streaming(options: options)
            ),
            options: options,
            decoder: decoder
        )
    }

    func stream<Output: Decodable & Sendable>(
        _ request: Request,
        in threadID: String,
        response outputType: Output.Type,
        responseContract: AgentResponseContract,
        options: AgentStructuredStreamingOptions = AgentStructuredStreamingOptions(),
        decoder: JSONDecoder = JSONDecoder()
    ) async throws -> AsyncThrowingStream<AgentStructuredStreamEvent<Output>, Error> {
        try await startStructuredRequest(request, in: threadID, response: outputType,
            responseContract: responseContract, options: options, decoder: decoder).events
    }

    func streamRequest(
        _ request: Request,
        in threadID: String,
        responseContract: AgentResponseContract?,
        completionCapture: AgentTurnCompletionCapture? = nil,
        oneShotValidation: AgentOneShotResponseValidation? = nil
    ) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        try await startRequest(request, in: threadID, responseContract: responseContract,
            completionCapture: completionCapture, oneShotValidation: oneShotValidation).events
    }
}
