import Foundation

extension AgentRuntime {
    public func start<Format: AgentOutputFormat>(
        _ request: Request,
        in threadID: String,
        output format: Format
    ) async throws -> AgentExecution<AgentOutputEvent<Format.Event, Format.Output>> {
        try await startOutput(request, in: threadID, output: format)
    }

    private func startOutput<Format: AgentOutputFormat>(
        _ request: Request, in threadID: String, output format: Format,
        completionCapture: AgentTurnCompletionCapture? = nil
    ) async throws -> AgentExecution<AgentOutputEvent<Format.Event, Format.Output>> {
        let preparedOutput = try AgentPreparedOutput(format, isEphemeral: request.isEphemeral)
        let decoder = try format.makeDecoder()
        var request = request
        request.usesOutputRouting = true
        let contract = format.nativeJSONSchema.map { AgentResponseContract(format: $0, deliveryMode: .oneShot) }
        let prepared: PreparedTurn
        do {
            prepared = try await prepareTurn(request, in: threadID, responseContract: contract)
        } catch {
            await decoder.cancel()
            throw error
        }
        let control = AgentExecutionControl(threadID: threadID, execution: prepared.execution)
        let channel = AgentEventChannel<AgentOutputEvent<Format.Event, Format.Output>>.makeStream(
            capacity: min(maximumBufferedEvents, format.limits.maximumQueuedEventCount),
            maximumBufferedBytes: format.limits.maximumQueuedEventBytes)
        let box = AgentOutputResultBox<Format.Event, Format.Output>()
        let session = AgentOutputSession(
            prepared: preparedOutput, decoder: decoder, executionID: control.id,
            threadID: threadID, channel: channel.continuation, box: box)
        control.outputStarted = { box.hasStarted }
        let sink = AgentTurnEventSink<JSONValue>(
            emit: { try await channel.continuation.yield(.lifecycle($0)) },
            partial: { _ in }, committed: { _ in }, validationFailed: { _ in },
            complete: { error, events in
                channel.continuation.finish(throwing: error, finalElements: box.terminal(events, error: error))
            },
            onCancellation: { channel.continuation.onCancellation($0) })
        launchTurn(
            prepared, control: control, structured: nil, completionCapture: completionCapture,
            output: session.erased, sink: sink)
        return .init(events: channel.stream, control: control)
    }

    public func stream<Format: AgentOutputFormat>(
        _ request: Request,
        in threadID: String,
        output: Format
    ) async throws -> AsyncThrowingStream<AgentOutputEvent<Format.Event, Format.Output>, Error> {
        try await start(request, in: threadID, output: output).events
    }

    public func send<Format: AgentOutputFormat>(
        _ request: Request,
        in threadID: String,
        output: Format
    ) async throws -> Format.Output {
        try await sendWithSummary(request, in: threadID, output: output).value
    }

    public func sendWithSummary<Format: AgentOutputFormat>(
        _ request: Request,
        in threadID: String,
        output: Format
    ) async throws -> AgentTurnResult<Format.Output> {
        let capture = AgentTurnCompletionCapture()
        let stream = try await startOutput(request, in: threadID, output: output, completionCapture: capture).events
        var value: Format.Output?
        var summary: AgentTurnSummary?
        for try await event in stream {
            switch event {
            case let .outputCommitted(_, output): value = output
            case let .lifecycle(.turnCompleted(result)): summary = result
            default: break
            }
        }
        guard let value, let summary else {
            throw AgentOutputError.invalidOutput("Missing committed output or turn summary.")
        }
        return AgentTurnResult(
            value: value, summary: summary, clientRequestID: request.clientRequestID,
            memoryApplication: await capture.memoryApplication())
    }

    public func fetchLatestOutput<Format: AgentOutputFormat>(
        in threadID: String,
        output: Format
    ) async throws -> Format.Output? {
        guard let metadata = try await fetchLatestStructuredOutputMetadata(id: threadID),
            metadata.formatName == output.name
        else { return nil }
        // Existing stores retain a redacted metadata tombstone for audit queries.
        if metadata.payload == .object(["redacted": .bool(true)]) { return nil }
        guard let representation = metadata.outputRepresentation else { throw AgentOutputError.unsupportedVersion }
        return try representation.restore(using: output)
    }
}
