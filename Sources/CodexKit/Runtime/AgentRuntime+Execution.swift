import Foundation

extension AgentRuntime {
    public func start(_ request: Request, in threadID: String) async throws -> AgentExecution<AgentEvent> {
        try await startRequest(request, in: threadID, responseContract: nil)
    }

    public func start<Output: AgentStructuredOutput>(
        _ request: Request, in threadID: String, response: Output.Type,
        options: AgentStructuredStreamingOptions = .init(), decoder: JSONDecoder = JSONDecoder()
    ) async throws -> AgentExecution<AgentStructuredStreamEvent<Output>> {
        try await startStructuredRequest(request, in: threadID, response: response,
            responseContract: .init(format: Output.responseFormat, deliveryMode: .streaming(options: options)),
            options: options, decoder: decoder)
    }

    func startRequest(
        _ request: Request, in threadID: String, responseContract: AgentResponseContract?,
        completionCapture: AgentTurnCompletionCapture? = nil,
        oneShotValidation: AgentOneShotResponseValidation? = nil
    ) async throws -> AgentExecution<AgentEvent> {
        let prepared = try await prepareTurn(request, in: threadID, responseContract: responseContract)
        let control = AgentExecutionControl(threadID: threadID, execution: prepared.execution)
        let channel = AgentEventChannel<AgentEvent>.makeStream(capacity: maximumBufferedEvents)
        launchTurn(prepared, control: control, structured: nil, completionCapture: completionCapture,
            oneShotValidation: oneShotValidation,
            sink: AgentTurnEventSink<JSONValue>(channel.continuation))
        return AgentExecution(events: channel.stream, control: control)
    }

    func startStructuredRequest<Output: Decodable & Sendable>(
        _ request: Request, in threadID: String, response: Output.Type, responseContract: AgentResponseContract,
        options: AgentStructuredStreamingOptions, decoder: JSONDecoder
    ) async throws -> AgentExecution<AgentStructuredStreamEvent<Output>> {
        let prepared = try await prepareTurn(request, in: threadID, responseContract: responseContract)
        let control = AgentExecutionControl(threadID: threadID, execution: prepared.execution)
        let structured = AgentStructuredTurnConfiguration<Output>(format: responseContract.format, options: options, decoder: decoder)
        let channel = AgentEventChannel<AgentStructuredStreamEvent<Output>>.makeStream(capacity: maximumBufferedEvents)
        launchTurn(prepared, control: control, structured: structured, sink: AgentTurnEventSink(channel.continuation))
        return AgentExecution(events: channel.stream, control: control)
    }
}
