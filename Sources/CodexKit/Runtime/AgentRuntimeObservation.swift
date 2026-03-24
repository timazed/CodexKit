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

public final class AgentRuntimeObservationCenter: @unchecked Sendable {
    private let lock = NSLock()
    private let subject = PassthroughSubject<AgentRuntimeObservation, Never>()
    private let threadsSubject = CurrentValueSubject<[AgentThread], Never>([])
    private var threadSubjects: [String: CurrentValueSubject<AgentThread?, Never>] = [:]
    private var messageSubjects: [String: CurrentValueSubject<[AgentMessage], Never>] = [:]
    private var summarySubjects: [String: CurrentValueSubject<AgentThreadSummary?, Never>] = [:]
    private var contextStateSubjects: [String: CurrentValueSubject<AgentThreadContextState?, Never>] = [:]
    private var contextUsageSubjects: [String: CurrentValueSubject<AgentThreadContextUsage?, Never>] = [:]

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

    private func threadSubject(for threadID: String) -> CurrentValueSubject<AgentThread?, Never> {
        if let subject = threadSubjects[threadID] {
            return subject
        }
        let subject = CurrentValueSubject<AgentThread?, Never>(nil)
        threadSubjects[threadID] = subject
        return subject
    }

    private func messageSubject(for threadID: String) -> CurrentValueSubject<[AgentMessage], Never> {
        if let subject = messageSubjects[threadID] {
            return subject
        }
        let subject = CurrentValueSubject<[AgentMessage], Never>([])
        messageSubjects[threadID] = subject
        return subject
    }

    private func summarySubject(for threadID: String) -> CurrentValueSubject<AgentThreadSummary?, Never> {
        if let subject = summarySubjects[threadID] {
            return subject
        }
        let subject = CurrentValueSubject<AgentThreadSummary?, Never>(nil)
        summarySubjects[threadID] = subject
        return subject
    }

    private func contextStateSubject(for threadID: String) -> CurrentValueSubject<AgentThreadContextState?, Never> {
        if let subject = contextStateSubjects[threadID] {
            return subject
        }
        let subject = CurrentValueSubject<AgentThreadContextState?, Never>(nil)
        contextStateSubjects[threadID] = subject
        return subject
    }

    private func contextUsageSubject(for threadID: String) -> CurrentValueSubject<AgentThreadContextUsage?, Never> {
        if let subject = contextUsageSubjects[threadID] {
            return subject
        }
        let subject = CurrentValueSubject<AgentThreadContextUsage?, Never>(nil)
        contextUsageSubjects[threadID] = subject
        return subject
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

extension AgentRuntime {
    public nonisolated func observeThreads() -> AnyPublisher<[AgentThread], Never> {
        observationCenter.threadListPublisher
    }

    public nonisolated func observeThread(id threadID: String) -> AnyPublisher<AgentThread?, Never> {
        observationCenter.threadPublisher(for: threadID)
    }

    public nonisolated func observeMessages(in threadID: String) -> AnyPublisher<[AgentMessage], Never> {
        observationCenter.messagePublisher(for: threadID)
    }

    public nonisolated func observeThreadSummary(id threadID: String) -> AnyPublisher<AgentThreadSummary?, Never> {
        observationCenter.threadSummaryPublisher(for: threadID)
    }

    public nonisolated func observeThreadContextState(id threadID: String) -> AnyPublisher<AgentThreadContextState?, Never> {
        observationCenter.threadContextStatePublisher(for: threadID)
    }

    public nonisolated func observeThreadContextUsage(id threadID: String) -> AnyPublisher<AgentThreadContextUsage?, Never> {
        observationCenter.threadContextUsagePublisher(for: threadID)
    }
}
