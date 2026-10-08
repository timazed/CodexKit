import Foundation

/// One logical provider response (or an attempt with unknown usage), distinct from a turn aggregate.
/// Delivery can repeat. Deduplicate by `id`; reading a saved receipt retains that identity.
public struct AgentUsageObservation: Codable, Hashable, Sendable, Identifiable {
    public enum Outcome: String, Codable, Hashable, Sendable { case completed, failed, incomplete, unknown }
    public let id: String
    public let threadID: String
    public let turnID: String
    public let requestID: String
    public let passNumber: Int
    public let attemptID: String
    public let responseID: String?
    public let operationID: UUID?
    public let rootOperationID: UUID?
    public let model: String
    public let reasoningEffort: ReasoningEffort
    public let outcome: Outcome
    public let usage: AgentUsage
    public internal(set) var isReused: Bool = false

    var reused: Self { var copy = self; copy.isReused = true; return copy }

    var logMetadata: [String: String] {
        var metadata = usage.logMetadata
        metadata.merge([
            "event": "usage.response.observed", "event_version": "1", "usage_scope": "response",
            "usage_id": id, "thread_id": threadID, "turn_id": turnID, "request_id": requestID,
            "pass_number": String(passNumber), "attempt_id": attemptID,
            "model": model, "reasoning_effort": reasoningEffort.rawValue,
            "outcome": outcome.rawValue, "usage_reused": String(isReused)
        ]) { _, new in new }
        metadata["provider_response_id"] = responseID
        metadata["operation_id"] = operationID?.uuidString
        metadata["root_operation_id"] = rootOperationID?.uuidString
        return metadata
    }
}

extension AgentUsage {
    var logMetadata: [String: String] {
        var metadata: [String: String] = ["usage_reporting": coverage == nil ? "unknown" : "observed"]
        if let coverage {
            metadata["usage_response_count"] = String(coverage.responseCount)
            metadata["usage_reported_response_count"] = String(coverage.usageReportedResponseCount)
            if !coverage.invalidMetrics.isEmpty {
                metadata["usage_invalid_metrics"] = coverage.invalidMetrics.map(\.rawValue).sorted().joined(separator: ",")
            }
            if !coverage.overflowedMetrics.isEmpty {
                metadata["usage_overflowed_metrics"] = coverage.overflowedMetrics.map(\.rawValue).sorted().joined(separator: ",")
            }
        }
        let values: [AgentUsageMetric: String?] = [
            .inputTokens: String(inputTokens), .cachedInputTokens: String(cachedInputTokens),
            .outputTokens: String(outputTokens), .cacheWriteInputTokens: cacheWriteInputTokens.map(String.init),
            .reasoningOutputTokens: reasoningOutputTokens.map(String.init), .totalTokens: totalTokens.map(String.init),
            .codexRolloutBudgetUnits: codexRolloutBudgetUnits.map { String($0) }
        ]
        for metric in AgentUsageMetric.allCases {
            let availability = availability(of: metric)
            metadata[metric.rawValue + "_availability"] = availability.rawValue
            if availability == .complete || availability == .partial { metadata[metric.rawValue] = values[metric] ?? nil }
            if let coverage { metadata[metric.rawValue + "_reported_responses"] = String(coverage.reportedResponses[metric, default: 0]) }
        }
        return metadata
    }

    static func aggregateLogMetadata(_ usage: Self?, scope: String, event: String) -> [String: String] {
        var metadata = (usage ?? .unavailable()).logMetadata
        metadata["usage_scope"] = scope
        metadata["event"] = event
        metadata["event_version"] = "1"
        return metadata
    }
}

/// Lifetime is one turn/operation; no process-wide response journal.
struct AgentUsageAccumulator {
    private(set) var observations: [AgentUsageObservation] = []
    private var identities: Set<String> = []
    private(set) var usage = AgentUsage.unavailable(responseCount: 0)

    @discardableResult mutating func insert(_ observation: AgentUsageObservation) -> Bool {
        guard identities.insert(observation.id).inserted else {
            // A terminal replay can fill in an earlier disconnect's unknown usage without adding spend.
            guard observation.outcome != .unknown,
                  let index = observations.firstIndex(where: { $0.id == observation.id && $0.outcome == .unknown }) else { return false }
            observations[index] = observation
            usage = .unavailable(responseCount: 0)
            for value in observations { usage.add(value.usage) }
            return true
        }
        observations.append(observation)
        usage.add(observation.usage)
        return true
    }
}
