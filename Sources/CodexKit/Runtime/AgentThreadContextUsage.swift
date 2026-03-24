import Foundation

public struct AgentThreadContextUsage: Codable, Hashable, Sendable {
    public let threadID: String
    public let visibleEstimatedTokenCount: Int
    public let effectiveEstimatedTokenCount: Int
    public let modelContextWindowTokenCount: Int?
    public let usableContextWindowTokenCount: Int?

    public init(
        threadID: String,
        visibleEstimatedTokenCount: Int,
        effectiveEstimatedTokenCount: Int,
        modelContextWindowTokenCount: Int? = nil,
        usableContextWindowTokenCount: Int? = nil
    ) {
        self.threadID = threadID
        self.visibleEstimatedTokenCount = visibleEstimatedTokenCount
        self.effectiveEstimatedTokenCount = effectiveEstimatedTokenCount
        self.modelContextWindowTokenCount = modelContextWindowTokenCount
        self.usableContextWindowTokenCount = usableContextWindowTokenCount
    }
}

public extension AgentThreadContextUsage {
    var estimatedTokenSavings: Int {
        max(0, visibleEstimatedTokenCount - effectiveEstimatedTokenCount)
    }

    var percentUsed: Int? {
        guard let usableContextWindowTokenCount,
              usableContextWindowTokenCount > 0 else {
            return nil
        }

        let percent = Double(effectiveEstimatedTokenCount) / Double(usableContextWindowTokenCount) * 100
        return min(100, Int(percent.rounded()))
    }
}

public protocol AgentBackendContextWindowProviding: Sendable {
    var modelContextWindowTokenCount: Int? { get }
    var usableContextWindowTokenCount: Int? { get }
}
