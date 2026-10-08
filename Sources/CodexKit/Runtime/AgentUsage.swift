import Foundation

/// Provider token counts. Cached input is included in input; reasoning is included in output.
public struct AgentUsage: Codable, Hashable, Sendable {
    public var inputTokens: Int
    public var cachedInputTokens: Int
    public var outputTokens: Int
    public var cacheWriteInputTokens: Int?
    public var reasoningOutputTokens: Int?
    /// Provider-reported total, never synthesized from the other counts.
    public var totalTokens: Int?
    /// Opaque provider units, not tokens, money, or a subscription percentage.
    public var codexRolloutBudgetUnits: Double?
    /// Nil for historical records and callers using the original initializer: presence is unknown.
    public var coverage: AgentUsageCoverage?

    public init(inputTokens: Int = 0, cachedInputTokens: Int = 0, outputTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
    }

    /// Explicitly derived input + output, available only with complete coverage and no overflow.
    public var derivedTotalTokens: Int? {
        guard availability(of: .inputTokens) == .complete, availability(of: .outputTokens) == .complete else { return nil }
        let sum = inputTokens.addingReportingOverflow(outputTokens)
        return sum.overflow ? nil : sum.partialValue
    }

    public func availability(of metric: AgentUsageMetric) -> AgentUsageAvailability {
        guard let coverage else { return .unknown }
        let count = coverage.reportedResponses[metric, default: 0]
        if count == 0 { return .unavailable }
        return count == coverage.responseCount ? .complete : .partial
    }

    static func unavailable(responseCount: Int = 1) -> Self {
        var usage = Self()
        usage.coverage = .init(responseCount: responseCount)
        return usage
    }

    mutating func add(_ other: Self) {
        var combined = coverage ?? .init(responseCount: 1)
        let incoming = other.coverage ?? .init(responseCount: 1)
        combined.responseCount += incoming.responseCount
        combined.usageReportedResponseCount += incoming.usageReportedResponseCount
        combined.invalidMetrics.formUnion(incoming.invalidMetrics)
        combined.overflowedMetrics.formUnion(incoming.overflowedMetrics)
        for metric in AgentUsageMetric.allCases {
            combined.reportedResponses[metric, default: 0] += incoming.reportedResponses[metric, default: 0]
        }
        func sum(_ lhs: Int?, _ rhs: Int?, metric: AgentUsageMetric) -> Int? {
            guard lhs != nil || rhs != nil else { return nil }
            let value = (lhs ?? 0).addingReportingOverflow(rhs ?? 0)
            if value.overflow || combined.overflowedMetrics.contains(metric) || incoming.overflowedMetrics.contains(metric) {
                combined.overflowedMetrics.insert(metric)
                combined.reportedResponses[metric] = 0
                return nil
            }
            return value.partialValue
        }
        inputTokens = sum(inputTokens, other.inputTokens, metric: .inputTokens) ?? 0
        cachedInputTokens = sum(cachedInputTokens, other.cachedInputTokens, metric: .cachedInputTokens) ?? 0
        outputTokens = sum(outputTokens, other.outputTokens, metric: .outputTokens) ?? 0
        cacheWriteInputTokens = sum(cacheWriteInputTokens, other.cacheWriteInputTokens, metric: .cacheWriteInputTokens)
        reasoningOutputTokens = sum(reasoningOutputTokens, other.reasoningOutputTokens, metric: .reasoningOutputTokens)
        totalTokens = sum(totalTokens, other.totalTokens, metric: .totalTokens)
        if codexRolloutBudgetUnits != nil || other.codexRolloutBudgetUnits != nil {
            let value = (codexRolloutBudgetUnits ?? 0) + (other.codexRolloutBudgetUnits ?? 0)
            if value.isFinite && !combined.overflowedMetrics.contains(.codexRolloutBudgetUnits) &&
                !incoming.overflowedMetrics.contains(.codexRolloutBudgetUnits) {
                codexRolloutBudgetUnits = value
            } else {
                codexRolloutBudgetUnits = nil
                combined.overflowedMetrics.insert(.codexRolloutBudgetUnits)
                combined.reportedResponses[.codexRolloutBudgetUnits] = 0
            }
        }
        coverage = combined
    }
}

public enum AgentUsageMetric: String, Codable, CaseIterable, Hashable, Sendable {
    case inputTokens = "input_tokens"
    case cachedInputTokens = "cached_input_tokens"
    case cacheWriteInputTokens = "cache_write_input_tokens"
    case outputTokens = "output_tokens"
    case reasoningOutputTokens = "reasoning_output_tokens"
    case totalTokens = "total_tokens"
    case codexRolloutBudgetUnits = "codex_rollout_budget_units"
}

public enum AgentUsageAvailability: String, Codable, Hashable, Sendable {
    case unknown, unavailable, partial, complete
}

/// Coverage counts include attempts that ended without a usage-bearing response.
public struct AgentUsageCoverage: Codable, Hashable, Sendable {
    public var responseCount: Int
    public var usageReportedResponseCount: Int = 0
    public var reportedResponses: [AgentUsageMetric: Int] = [:]
    /// Fixed field identifiers only; malformed provider values are never retained here.
    public var invalidMetrics: Set<AgentUsageMetric> = []
    public var overflowedMetrics: Set<AgentUsageMetric> = []
}
