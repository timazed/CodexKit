import Combine
import Foundation

public enum AgentRuntimeObservation: Sendable {
    case threadsChanged([AgentThread])
    case threadChanged(AgentThread)
    case messagesChanged(threadID: String, messages: [AgentMessage])
    case threadSummaryChanged(AgentThreadSummary)
    case threadContextStateChanged(threadID: String, state: AgentThreadContextState?)
    case threadDeleted(threadID: String)
}

public final class AgentRuntimeObservationCenter: @unchecked Sendable {
    private let subject = PassthroughSubject<AgentRuntimeObservation, Never>()

    public init() {}

    public var publisher: AnyPublisher<AgentRuntimeObservation, Never> {
        subject.eraseToAnyPublisher()
    }

    func send(_ observation: AgentRuntimeObservation) {
        subject.send(observation)
    }
}
