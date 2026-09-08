import Combine
import Foundation

public enum AgentObservationBuffering: Sendable {
    /// Coalesces snapshots to the newest value. Suitable for current state.
    case latest
    /// Preserves admitted values; overflow ends observation with a typed error.
    /// Capacity is clamped to 1...4,096. Suitable for change notifications.
    case buffered(limit: Int)
}

/// One consumer per sequence. Retaining either this sequence or its iterator
/// retains the subscription; cancellation and releasing both unsubscribe.
public struct AgentObservationSequence<Element: Sendable>: AsyncSequence, Sendable {
    public struct AsyncIterator: AsyncIteratorProtocol {
        private var iterator: AsyncThrowingStream<Element, Error>.Iterator
        private let lifetime: ObservationSubscription

        fileprivate init(stream: AsyncThrowingStream<Element, Error>, lifetime: ObservationSubscription) {
            iterator = stream.makeAsyncIterator()
            self.lifetime = lifetime
        }

        public mutating func next() async throws -> Element? {
            defer { withExtendedLifetime(lifetime) {} }
            return try await iterator.next()
        }
    }

    private let stream: AsyncThrowingStream<Element, Error>
    private let lifetime: ObservationSubscription

    init(publisher: AnyPublisher<Element, Never>, buffering: AgentObservationBuffering) {
        let lifetime = ObservationSubscription()
        self.lifetime = lifetime
        let policy: AsyncThrowingStream<Element, Error>.Continuation.BufferingPolicy
        switch buffering {
        case .latest: policy = .bufferingNewest(1)
        case let .buffered(limit): policy = .bufferingOldest(Swift.max(1, Swift.min(limit, 4_096)))
        }
        stream = AsyncThrowingStream(bufferingPolicy: policy) { continuation in
            continuation.onTermination = { [weak lifetime] _ in lifetime?.cancel() }
            let token = publisher.sink(receiveCompletion: { _ in continuation.finish() }, receiveValue: { value in
                if case .dropped = continuation.yield(value), case .buffered = buffering {
                    continuation.finish(throwing: AgentRuntimeError(code: "observation_buffer_overflow",
                        message: "Observation exceeded its buffer. Resubscribe and reload state, or use latest-value buffering for snapshots."))
                }
            })
            lifetime.install(token)
        }
    }

    public func makeAsyncIterator() -> AsyncIterator { .init(stream: stream, lifetime: lifetime) }
}

public extension AgentRuntimeObservationPublisher {
    /// Buffers up to 64 notifications; overflow fails instead of losing changes.
    var values: AgentObservationSequence<Output> { values(buffering: .buffered(limit: 64)) }

    func values(buffering: AgentObservationBuffering) -> AgentObservationSequence<Output> {
        .init(publisher: eraseToAnyPublisher(), buffering: buffering)
    }
}

private final class ObservationSubscription: @unchecked Sendable {
    private let lock = NSLock()
    private var token: AnyCancellable?
    private var cancelled = false

    func install(_ token: AnyCancellable) {
        let shouldCancel = lock.withLock {
            if cancelled { return true }
            self.token = token
            return false
        }
        if shouldCancel { token.cancel() }
    }

    func cancel() {
        let token = lock.withLock {
            cancelled = true
            defer { self.token = nil }
            return self.token
        }
        token?.cancel()
    }

    deinit { cancel() }
}
