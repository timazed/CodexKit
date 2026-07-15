import Foundation

extension AgentRuntime {
    func threadContextUsage(for threadID: String) async -> AgentThreadContextUsage? {
        guard state.threads.contains(where: { $0.id == threadID }) else {
            return nil
        }

        let visibleMessages = state.messagesByThread[threadID] ?? []
        let effectiveMessages = effectiveHistory(for: threadID)

        return AgentThreadContextUsage(
            threadID: threadID,
            visibleEstimatedTokenCount: approximateTokenCount(for: visibleMessages),
            effectiveEstimatedTokenCount: approximateTokenCount(for: effectiveMessages),
            modelContextWindowTokenCount: await modelContextWindowTokenCount(),
            usableContextWindowTokenCount: await usableContextWindowTokenCount()
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

    private func modelContextWindowTokenCount() async -> Int? {
        await (backend as? any AgentBackendContextWindowProviding)?.modelContextWindowTokenCount
    }

    private func usableContextWindowTokenCount() async -> Int? {
        await (backend as? any AgentBackendContextWindowProviding)?.usableContextWindowTokenCount
    }
}
