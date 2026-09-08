import Foundation

/// A bounded, lossless queue. Producers await capacity; the public stream pulls
/// directly from this queue and does not introduce a second unbounded buffer.
final class AgentEventChannel<Element: Sendable>: @unchecked Sendable {
    private struct Sender {
        let id: UUID
        let element: Element
        let continuation: CheckedContinuation<Void, Error>
    }

    private final class Lifetime: Sendable {
        let channel: AgentEventChannel
        init(_ channel: AgentEventChannel) { self.channel = channel }
        deinit { channel.cancel() }
    }

    private let lock = NSLock()
    private var buffer: [Element?]
    private var head = 0
    private var count = 0
    private var peakCount = 0
    private var senders: [Sender] = []
    private var receivers: [CheckedContinuation<Element?, Error>] = []
    private var terminal: Result<Void, Error>?
    private var terminalElements: [Element] = []
    private var didCancel = false
    private var cancellationHandler: (@Sendable () -> Void)?

    init(capacity: Int = 64) {
        buffer = Array(repeating: nil, count: max(1, min(capacity, 4_096)))
    }

    static func makeStream(capacity: Int = 64) -> (
        stream: AsyncThrowingStream<Element, Error>, continuation: AgentEventChannel
    ) {
        let channel = AgentEventChannel(capacity: capacity)
        let lifetime = Lifetime(channel)
        return (AsyncThrowingStream(unfolding: { try await lifetime.channel.next() }), channel)
    }

    func onCancellation(_ handler: @escaping @Sendable () -> Void) {
        let invoke = lock.withLock {
            if didCancel { return true }
            if terminal == nil { cancellationHandler = handler }
            return false
        }
        if invoke { handler() }
    }

    func yield(_ element: Element) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                var receiver: CheckedContinuation<Element?, Error>?
                let result: Result<Void, Error>? = lock.withLock {
                    if Task.isCancelled { return .failure(CancellationError()) }
                    if let terminal { return .failure(terminal.failure ?? CancellationError()) }
                    if !receivers.isEmpty {
                        receiver = receivers.removeFirst()
                        return .success(())
                    }
                    if count < buffer.count {
                        append(element)
                        return .success(())
                    }
                    senders.append(Sender(id: id, element: element, continuation: continuation))
                    return nil
                }
                receiver?.resume(returning: element)
                if let result { continuation.resume(with: result) }
            }
            try Task.checkCancellation()
        } onCancel: {
            self.cancelSender(id)
        }
    }

    /// At most four lifecycle events may bypass capacity at termination. They
    /// follow all admitted events, even if a producer was cancelled while full.
    func finish(throwing error: Error? = nil, finalElements: [Element] = []) {
        precondition(finalElements.count <= 4)
        let result: Result<Void, Error> = error.map { .failure($0) } ?? .success(())
        var deliveries: [(CheckedContinuation<Element?, Error>, Result<Element?, Error>)] = []
        let blocked: [Sender] = lock.withLock {
            guard terminal == nil else { return [] }
            terminal = result
            terminalElements = finalElements
            cancellationHandler = nil
            for receiver in receivers {
                if !terminalElements.isEmpty {
                    deliveries.append((receiver, .success(terminalElements.removeFirst())))
                } else {
                    deliveries.append((receiver, result.map { nil }))
                }
            }
            receivers.removeAll()
            let pending = senders
            senders.removeAll()
            return pending
        }
        blocked.forEach { $0.continuation.resume(throwing: error ?? CancellationError()) }
        deliveries.forEach { $0.0.resume(with: $0.1) }
    }

    func cancel() {
        var blocked: [Sender] = []
        var waiting: [CheckedContinuation<Element?, Error>] = []
        let handler = lock.withLock {
            didCancel = true
            terminal = .failure(CancellationError())
            buffer = Array(repeating: nil, count: buffer.count)
            count = 0
            terminalElements.removeAll()
            blocked = senders
            senders.removeAll()
            waiting = receivers
            receivers.removeAll()
            let handler = cancellationHandler
            cancellationHandler = nil
            return handler
        }
        blocked.forEach { $0.continuation.resume(throwing: CancellationError()) }
        waiting.forEach { $0.resume(throwing: CancellationError()) }
        handler?()
    }

    var diagnostics: (buffered: Int, peakBuffered: Int, waitingProducers: Int) {
        lock.withLock { (count, peakCount, senders.count) }
    }

    private func next() async throws -> Element? {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                var sender: Sender?
                let result: Result<Element?, Error>? = lock.withLock {
                    if Task.isCancelled { return .failure(CancellationError()) }
                    if count > 0 {
                        let element = buffer[head]
                        buffer[head] = nil
                        head = (head + 1) % buffer.count
                        count -= 1
                        if !senders.isEmpty {
                            sender = senders.removeFirst()
                            append(sender!.element)
                        }
                        return .success(element)
                    }
                    if !terminalElements.isEmpty { return .success(terminalElements.removeFirst()) }
                    if let terminal { return terminal.map { nil } }
                    receivers.append(continuation)
                    return nil
                }
                sender?.continuation.resume()
                if let result { continuation.resume(with: result) }
            }
        } onCancel: {
            self.cancel()
        }
    }

    private func append(_ element: Element) {
        buffer[(head + count) % buffer.count] = element
        count += 1
        peakCount = max(peakCount, count)
    }

    private func cancelSender(_ id: UUID) {
        let sender: Sender? = lock.withLock {
            guard let index = senders.firstIndex(where: { $0.id == id }) else { return nil }
            return senders.remove(at: index)
        }
        sender?.continuation.resume(throwing: CancellationError())
    }
}

private extension Result where Success == Void, Failure == Error {
    var failure: Error? {
        if case let .failure(error) = self { return error }
        return nil
    }
}
