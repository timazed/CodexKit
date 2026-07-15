import Foundation

extension AgentRuntime {
    func threadContextUsage(for threadID: String) async -> AgentThreadContextUsage? {
        guard state.threads.contains(where: { $0.id == threadID }) else {
            return nil
        }

        let visibleMessages = state.messagesByThread[threadID] ?? []
        let effectiveMessages = effectiveHistory(for: threadID)
        let model = state.threads.first(where: { $0.id == threadID })?.configuration?.model

        return AgentThreadContextUsage(
            threadID: threadID,
            visibleEstimatedTokenCount: approximateTokenCount(for: visibleMessages),
            effectiveEstimatedTokenCount: approximateTokenCount(for: effectiveMessages),
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
                total += message.text.count + (message.images.count * 512)
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
