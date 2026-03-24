import Combine
import CodexKit
import Foundation

@MainActor
extension AgentDemoViewModel {
    func configureRuntimeObservationBindings() {
        runtimeObservationCancellables.removeAll()

        runtime.observeThreads()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] threads in
                guard let self else {
                    return
                }

                self.threads = threads
                if let activeThreadID = self.activeThreadID,
                   !threads.contains(where: { $0.id == activeThreadID }) {
                    self.activeThreadID = nil
                    self.resetObservedThreadState()
                    self.messages = []
                } else if let activeThreadID = self.activeThreadID {
                    self.observedThread = threads.first { $0.id == activeThreadID }
                }
            }
            .store(in: &runtimeObservationCancellables)

        if let activeThreadID {
            bindActiveThreadObservation(for: activeThreadID)
        } else {
            resetObservedThreadState()
        }
    }

    func bindActiveThreadObservation(for threadID: String) {
        activeThreadObservationCancellables.removeAll()
        resetObservedThreadState()

        runtime.observeThread(id: threadID)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] thread in
                self?.observedThread = thread
            }
            .store(in: &activeThreadObservationCancellables)

        runtime.observeMessages(in: threadID)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] messages in
                guard let self else {
                    return
                }
                self.observedMessages = messages
                self.setMessages(messages)
            }
            .store(in: &activeThreadObservationCancellables)

        runtime.observeThreadSummary(id: threadID)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] summary in
                self?.observedThreadSummary = summary
            }
            .store(in: &activeThreadObservationCancellables)

        runtime.observeThreadContextState(id: threadID)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] contextState in
                guard let self else {
                    return
                }
                self.observedThreadContextState = contextState
                self.activeThreadContextState = contextState
            }
            .store(in: &activeThreadObservationCancellables)
    }

    func resetObservedThreadState() {
        observedThread = nil
        observedMessages = []
        observedThreadSummary = nil
        observedThreadContextState = nil
        activeThreadContextState = nil
    }
}
