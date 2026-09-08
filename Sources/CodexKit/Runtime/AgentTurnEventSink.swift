import Foundation

struct AgentStructuredTurnConfiguration<Output: Decodable & Sendable>: Sendable {
    let format: AgentStructuredOutputFormat
    let options: AgentStructuredStreamingOptions
    let decoder: JSONDecoder
}

/// Both public stream forms share lifecycle events and terminal handling.
struct AgentTurnEventSink<Output: Sendable>: Sendable {
    let emit: @Sendable (AgentEvent) async throws -> Void
    let partial: @Sendable (Output) async throws -> Void
    let committed: @Sendable (Output) async throws -> Void
    let validationFailed: @Sendable (AgentStructuredOutputValidationFailure) async throws -> Void
    let complete: @Sendable (Error?, [AgentEvent]) -> Void
    let onCancellation: @Sendable (@escaping @Sendable () -> Void) -> Void

    init(_ channel: AgentEventChannel<AgentEvent>) where Output == JSONValue {
        emit = { try await channel.yield($0) }
        partial = { _ in }
        committed = { _ in }
        validationFailed = { _ in }
        complete = { channel.finish(throwing: $0, finalElements: $1) }
        onCancellation = { channel.onCancellation($0) }
    }

    init(_ channel: AgentEventChannel<AgentStructuredStreamEvent<Output>>) {
        emit = { try await channel.yield(AgentStructuredStreamEvent($0)) }
        partial = { try await channel.yield(.structuredOutputPartial($0)) }
        committed = { try await channel.yield(.structuredOutputCommitted($0)) }
        validationFailed = { try await channel.yield(.structuredOutputValidationFailed($0)) }
        complete = { channel.finish(throwing: $0, finalElements: $1.map(AgentStructuredStreamEvent.init)) }
        onCancellation = { channel.onCancellation($0) }
    }

    func yield(_ event: AgentEvent) async throws { try await emit(event) }
    func finish(throwing error: Error? = nil, events: [AgentEvent] = []) { complete(error, events) }

}

extension AgentStructuredStreamEvent {
    init(_ event: AgentEvent) {
        switch event {
        case let .threadStarted(value): self = .threadStarted(value)
        case let .threadStatusChanged(id, status): self = .threadStatusChanged(threadID: id, status: status)
        case let .progress(value): self = .progress(value)
        case let .rateLimitsUpdated(value): self = .rateLimitsUpdated(value)
        case let .turnStarted(value): self = .turnStarted(value)
        case let .assistantMessageDelta(threadID, turnID, delta):
            self = .assistantMessageDelta(threadID: threadID, turnID: turnID, delta: delta)
        case let .messageCommitted(value): self = .messageCommitted(value)
        case let .approvalRequested(value): self = .approvalRequested(value)
        case let .approvalResolved(value): self = .approvalResolved(value)
        case let .toolCallStarted(value): self = .toolCallStarted(value)
        case let .toolCallFinished(value): self = .toolCallFinished(value)
        case let .turnCompleted(value): self = .turnCompleted(value)
        case let .turnInterrupted(value): self = .turnInterrupted(value)
        case let .turnFailed(value): self = .turnFailed(value)
        }
    }
}
