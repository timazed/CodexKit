import Foundation

extension AgentRuntime {
    func threadContextUsage(for threadID: String) async -> AgentThreadContextUsage? {
        guard let snapshot = makeThreadObservationSnapshot(for: threadID) else {
            return nil
        }

        return await threadContextUsage(for: snapshot)
    }

    func threadContextUsage(
        for snapshot: AgentRuntimeThreadObservationSnapshot
    ) async -> AgentThreadContextUsage {
        let threadID = snapshot.thread.id
        let model = snapshot.thread.configuration?.model

        return AgentThreadContextUsage(
            threadID: threadID,
            visibleEstimatedTokenCount: approximateTokenCount(for: snapshot.messages),
            effectiveEstimatedTokenCount: approximateTokenCount(for: snapshot.effectiveMessages),
            modelContextWindowTokenCount: await modelContextWindowTokenCount(for: model),
            usableContextWindowTokenCount: await usableContextWindowTokenCount(for: model)
        )
    }

    func approximateTokenCount(for messages: [AgentMessage]) -> Int {
        guard !messages.isEmpty else {
            return 0
        }

        return max(
            1,
            messages.reduce(into: 0) { total, message in
                total += message.estimatedContextCharacterCount
            } / 4
        )
    }

    private func modelContextWindowTokenCount(for model: String?) async -> Int? {
        guard let provider = backend as? any AgentBackendContextWindowProviding else {
            return nil
        }
        if let model {
            return await provider.modelContextWindowTokenCount(for: model)
        }
        return await provider.modelContextWindowTokenCount
    }

    private func usableContextWindowTokenCount(for model: String?) async -> Int? {
        guard let provider = backend as? any AgentBackendContextWindowProviding else {
            return nil
        }
        if let model {
            return await provider.usableContextWindowTokenCount(for: model)
        }
        return await provider.usableContextWindowTokenCount
    }
}
