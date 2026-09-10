import Combine
import CodexKit
import Foundation

@MainActor
extension AgentDemoViewModel {
    func configureRuntimeObservationBindings() {
        runtimeObservationBindingTask?.cancel()
        activeThreadObservationBindingTask?.cancel()
        runtimeObservationCancellables.removeAll()
        activeThreadObservationCancellables.removeAll()
        resetObservedThreadState()

        let runtime = runtime

        runtimeObservationBindingTask = Task { @MainActor [weak self] in
            await self?.configureRuntimeObservationBindingsAsync(runtime: runtime)
        }
    }

    private func configureRuntimeObservationBindingsAsync(runtime: AgentRuntime) async {
        let publisher = await runtime.observeThreads()
        guard !Task.isCancelled else {
            return
        }

        publisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] threads in
                guard let self else {
                    return
                }

                self.threads = threads
                if let activeThreadID = self.activeThreadID,
                   !threads.contains(where: { $0.id == activeThreadID }) {
                    self.activeThreadID = nil
                    self.activeThreadObservationBindingTask?.cancel()
                    self.activeThreadObservationCancellables.removeAll()
                    self.resetObservedThreadState()
                    self.messages = []
                } else if let activeThreadID = self.activeThreadID {
                    self.observedThread = threads.first { $0.id == activeThreadID }
                }
            }
            .store(in: &runtimeObservationCancellables)

        guard !Task.isCancelled else {
            return
        }

        if let activeThreadID {
            bindActiveThreadObservation(for: activeThreadID)
        }
    }

    func bindActiveThreadObservation(for threadID: String) {
        activeThreadObservationBindingTask?.cancel()
        activeThreadObservationCancellables.removeAll()
        resetObservedThreadState()

        let runtime = runtime
        activeThreadObservationBindingTask = Task { @MainActor [weak self] in
            await self?.bindActiveThreadObservationAsync(
                for: threadID,
                runtime: runtime
            )
        }
    }

    private func bindActiveThreadObservationAsync(
        for threadID: String,
        runtime: AgentRuntime
    ) async {
        let threadPublisher = await runtime.observeThread(id: threadID)
        guard shouldContinueBinding(threadID: threadID) else {
            return
        }
        threadPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] thread in
                guard let self, self.activeThreadID == threadID else {
                    return
                }
                self.observedThread = thread
            }
            .store(in: &activeThreadObservationCancellables)

        let messagesPublisher = await runtime.observeMessages(in: threadID)
        guard shouldContinueBinding(threadID: threadID) else {
            return
        }
        messagesPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] messages in
                guard let self, self.activeThreadID == threadID else {
                    return
                }
                self.observedMessages = messages
                self.setMessages(messages)
            }
            .store(in: &activeThreadObservationCancellables)

        let summaryPublisher = await runtime.observeThreadSummary(id: threadID)
        guard shouldContinueBinding(threadID: threadID) else {
            return
        }
        summaryPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] summary in
                guard let self, self.activeThreadID == threadID else {
                    return
                }
                self.observedThreadSummary = summary
            }
            .store(in: &activeThreadObservationCancellables)

        let contextStatePublisher = await runtime.observeThreadContextState(id: threadID)
        guard shouldContinueBinding(threadID: threadID) else {
            return
        }
        contextStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] contextState in
                guard let self, self.activeThreadID == threadID else {
                    return
                }
                self.observedThreadContextState = contextState
                self.activeThreadContextState = contextState
            }
            .store(in: &activeThreadObservationCancellables)

        let contextUsagePublisher = await runtime.observeThreadContextUsage(id: threadID)
        guard shouldContinueBinding(threadID: threadID) else {
            return
        }
        contextUsagePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] contextUsage in
                guard let self, self.activeThreadID == threadID else {
                    return
                }
                self.observedThreadContextUsage = contextUsage
                self.activeThreadContextUsage = contextUsage
            }
            .store(in: &activeThreadObservationCancellables)
    }

    private func shouldContinueBinding(threadID: String) -> Bool {
        !Task.isCancelled && activeThreadID == threadID
    }

    func resetObservedThreadState() {
        observedThread = nil
        observedMessages = []
        observedThreadSummary = nil
        observedThreadContextState = nil
        activeThreadContextState = nil
        observedThreadContextUsage = nil
        activeThreadContextUsage = nil
    }

    func formattedTokenCount(_ tokens: Int) -> String {
        if tokens >= 1_000_000 {
            return String(format: "%.1fM", Double(tokens) / 1_000_000)
        }
        if tokens >= 1_000 {
            return String(format: "%.1fk", Double(tokens) / 1_000)
        }
        return "\(tokens)"
    }
}
