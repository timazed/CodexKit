import Combine
import Foundation

public enum AgentRuntimeObservation: Sendable {
    case threadsChanged([AgentThread])
    case threadChanged(AgentThread)
    case messagesChanged(threadID: String, messages: [AgentMessage])
    case threadSummaryChanged(AgentThreadSummary)
    case threadContextStateChanged(threadID: String, state: AgentThreadContextState?)
    case threadContextUsageChanged(threadID: String, usage: AgentThreadContextUsage?)
    case threadDeleted(threadID: String)
}

struct AgentRuntimeThreadObservationSnapshot: Sendable {
    let thread: AgentThread
    let messages: [AgentMessage]
    let summary: AgentThreadSummary
    let contextState: AgentThreadContextState?
    let effectiveMessages: [AgentMessage]
}

struct AgentRuntimeObservationBatchSnapshot: Sendable {
    let threadID: String
    let threadSnapshot: AgentRuntimeThreadObservationSnapshot?
    let isDeletion: Bool
}

public struct AgentRuntimeObservationPublisher<Output: Sendable>: Sendable {
    private let makePublisher: @Sendable () -> AnyPublisher<Output, Never>

    init(makePublisher: @escaping @Sendable () -> AnyPublisher<Output, Never>) {
        self.makePublisher = makePublisher
    }

    public func eraseToAnyPublisher() -> AnyPublisher<Output, Never> {
        makePublisher()
    }

    public func sink(receiveValue: @escaping (Output) -> Void) -> AnyCancellable {
        makePublisher().sink(receiveValue: receiveValue)
    }

    public func receive<S: Scheduler>(
        on scheduler: S,
        options: S.SchedulerOptions? = nil
    ) -> AnyPublisher<Output, Never> {
        makePublisher().receive(on: scheduler, options: options).eraseToAnyPublisher()
    }
}

// Combine subjects are reference types without Sendable conformance; access to
// subject registries is lock-protected and publishing is the class's purpose.
public final class AgentRuntimeObservationCenter: @unchecked Sendable {
    private let lock = NSLock()
    private let subject = PassthroughSubject<AgentRuntimeObservation, Never>()
    private let threadsSubject = CurrentValueSubject<[AgentThread], Never>([])
    private var threadSubjects = AgentObservationSubjects<AgentThread?>(initialValue: nil)
    private var messageSubjects = AgentObservationSubjects<[AgentMessage]>(initialValue: [])
    private var summarySubjects = AgentObservationSubjects<AgentThreadSummary?>(initialValue: nil)
    private var contextStateSubjects = AgentObservationSubjects<AgentThreadContextState?>(initialValue: nil)
    private var contextUsageSubjects = AgentObservationSubjects<AgentThreadContextUsage?>(initialValue: nil)

    public init() {}

    public var publisher: AnyPublisher<AgentRuntimeObservation, Never> {
        subject.eraseToAnyPublisher()
    }

    public var threadListPublisher: AnyPublisher<[AgentThread], Never> {
        threadsSubject.eraseToAnyPublisher()
    }

    public func threadPublisher(for threadID: String) -> AnyPublisher<AgentThread?, Never> {
        withLock {
            threadSubject(for: threadID).eraseToAnyPublisher()
        }
    }

    public func messagePublisher(for threadID: String) -> AnyPublisher<[AgentMessage], Never> {
        withLock {
            messageSubject(for: threadID).eraseToAnyPublisher()
        }
    }

    public func threadSummaryPublisher(for threadID: String) -> AnyPublisher<AgentThreadSummary?, Never> {
        withLock {
            summarySubject(for: threadID).eraseToAnyPublisher()
        }
    }

    public func threadContextStatePublisher(for threadID: String) -> AnyPublisher<AgentThreadContextState?, Never> {
        withLock {
            contextStateSubject(for: threadID).eraseToAnyPublisher()
        }
    }

    public func threadContextUsagePublisher(for threadID: String) -> AnyPublisher<AgentThreadContextUsage?, Never> {
        withLock {
            contextUsageSubject(for: threadID).eraseToAnyPublisher()
        }
    }

    func send(_ observation: AgentRuntimeObservation) {
        var updates: [() -> Void] = []

        withLock {
            switch observation {
            case let .threadsChanged(threads):
                updates.append { self.threadsSubject.send(threads) }

            case let .threadChanged(thread):
                let subject = threadSubject(for: thread.id)
                updates.append { subject.send(thread) }

            case let .messagesChanged(threadID, messages):
                let subject = messageSubject(for: threadID)
                updates.append { subject.send(messages) }

            case let .threadSummaryChanged(summary):
                let subject = summarySubject(for: summary.threadID)
                updates.append { subject.send(summary) }

            case let .threadContextStateChanged(threadID, state):
                let subject = contextStateSubject(for: threadID)
                updates.append { subject.send(state) }

            case let .threadContextUsageChanged(threadID, usage):
                let subject = contextUsageSubject(for: threadID)
                updates.append { subject.send(usage) }

            case let .threadDeleted(threadID):
                let threadSubject = threadSubject(for: threadID)
                let messageSubject = messageSubject(for: threadID)
                let summarySubject = summarySubject(for: threadID)
                let contextStateSubject = contextStateSubject(for: threadID)
                let contextUsageSubject = contextUsageSubject(for: threadID)
                updates.append { threadSubject.send(nil) }
                updates.append { messageSubject.send([]) }
                updates.append { summarySubject.send(nil) }
                updates.append { contextStateSubject.send(nil) }
                updates.append { contextUsageSubject.send(nil) }
            }
        }

        updates.forEach { $0() }
        subject.send(observation)
    }

    func deactivateThread(id threadID: String, activeThreads: [AgentThread]) {
        var updates: [() -> Void] = []
        withLock {
            if let threadSubject = threadSubjects.deactivate(threadID) {
                updates.append { threadSubject.send(nil) }
            }
            if let messageSubject = messageSubjects.deactivate(threadID) {
                updates.append { messageSubject.send([]) }
            }
            if let summarySubject = summarySubjects.deactivate(threadID) {
                updates.append { summarySubject.send(nil) }
            }
            if let contextStateSubject = contextStateSubjects.deactivate(threadID) {
                updates.append { contextStateSubject.send(nil) }
            }
            if let contextUsageSubject = contextUsageSubjects.deactivate(threadID) {
                updates.append { contextUsageSubject.send(nil) }
            }
            updates.append { self.threadsSubject.send(activeThreads) }
        }
        updates.forEach { $0() }
        subject.send(.threadsChanged(activeThreads))
        subject.send(.messagesChanged(threadID: threadID, messages: []))
        subject.send(.threadContextStateChanged(threadID: threadID, state: nil))
        subject.send(.threadContextUsageChanged(threadID: threadID, usage: nil))
    }

    private func threadSubject(for threadID: String) -> CurrentValueSubject<AgentThread?, Never> {
        threadSubjects.subject(for: threadID)
    }

    private func messageSubject(for threadID: String) -> CurrentValueSubject<[AgentMessage], Never> {
        messageSubjects.subject(for: threadID)
    }

    private func summarySubject(for threadID: String) -> CurrentValueSubject<AgentThreadSummary?, Never> {
        summarySubjects.subject(for: threadID)
    }

    private func contextStateSubject(for threadID: String) -> CurrentValueSubject<AgentThreadContextState?, Never> {
        contextStateSubjects.subject(for: threadID)
    }

    private func contextUsageSubject(for threadID: String) -> CurrentValueSubject<AgentThreadContextUsage?, Never> {
        contextUsageSubjects.subject(for: threadID)
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

extension AgentRuntime {
    public func observeThreads() -> AgentRuntimeObservationPublisher<[AgentThread]> {
        let observationCenter = observationCenter
        return AgentRuntimeObservationPublisher {
            observationCenter.threadListPublisher
        }
    }

    public func observeThread(id threadID: String) -> AgentRuntimeObservationPublisher<AgentThread?> {
        let observationCenter = observationCenter
        return AgentRuntimeObservationPublisher {
            observationCenter.threadPublisher(for: threadID)
        }
    }

    public func observeMessages(in threadID: String) -> AgentRuntimeObservationPublisher<[AgentMessage]> {
        let observationCenter = observationCenter
        return AgentRuntimeObservationPublisher {
            observationCenter.messagePublisher(for: threadID)
        }
    }

    public func observeThreadSummary(id threadID: String) -> AgentRuntimeObservationPublisher<AgentThreadSummary?> {
        let observationCenter = observationCenter
        return AgentRuntimeObservationPublisher {
            observationCenter.threadSummaryPublisher(for: threadID)
        }
    }

    public func observeThreadContextState(id threadID: String) -> AgentRuntimeObservationPublisher<AgentThreadContextState?> {
        let observationCenter = observationCenter
        return AgentRuntimeObservationPublisher {
            observationCenter.threadContextStatePublisher(for: threadID)
        }
    }

    public func observeThreadContextUsage(id threadID: String) -> AgentRuntimeObservationPublisher<AgentThreadContextUsage?> {
        let observationCenter = observationCenter
        return AgentRuntimeObservationPublisher {
            observationCenter.threadContextUsagePublisher(for: threadID)
        }
    }
}
