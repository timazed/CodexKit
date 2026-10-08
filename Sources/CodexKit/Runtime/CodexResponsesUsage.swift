import Foundation

/// Optional metrics must never turn valid generated content into a retryable decoding failure.
struct StreamUsage: Decodable {
    let assistantUsage: AgentUsage

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ value: String) { stringValue = value }
        init?(stringValue: String) { self.init(stringValue) }
        init?(intValue: Int) { return nil }
    }

    init(from decoder: Decoder) throws {
        var usage = AgentUsage.unavailable()
        guard let container = try? decoder.container(keyedBy: Key.self) else {
            usage.coverage?.invalidMetrics = Set(AgentUsageMetric.allCases)
            assistantUsage = usage
            return
        }
        usage.coverage?.usageReportedResponseCount = 1
        func integer(_ key: String, metric: AgentUsageMetric, details: String? = nil) -> Int? {
            var source = container
            if let details {
                let detailKey = Key(details)
                guard container.contains(detailKey), (try? container.decodeNil(forKey: detailKey)) != true else { return nil }
                guard let nested = try? container.nestedContainer(keyedBy: Key.self, forKey: detailKey) else {
                    usage.coverage?.invalidMetrics.insert(metric)
                    return nil
                }
                source = nested
            }
            let key = Key(key)
            guard source.contains(key), (try? source.decodeNil(forKey: key)) != true else { return nil }
            guard let value = try? source.decode(Int.self, forKey: key), value >= 0 else {
                usage.coverage?.invalidMetrics.insert(metric)
                return nil
            }
            usage.coverage?.reportedResponses[metric] = 1
            return value
        }
        usage.inputTokens = integer("input_tokens", metric: .inputTokens) ?? 0
        usage.cachedInputTokens = integer("cached_tokens", metric: .cachedInputTokens, details: "input_tokens_details") ?? 0
        usage.cacheWriteInputTokens = integer("cache_write_tokens", metric: .cacheWriteInputTokens, details: "input_tokens_details")
        usage.outputTokens = integer("output_tokens", metric: .outputTokens) ?? 0
        usage.reasoningOutputTokens = integer("reasoning_tokens", metric: .reasoningOutputTokens, details: "output_tokens_details")
        usage.totalTokens = integer("total_tokens", metric: .totalTokens)
        let budgetKey = Key("codex_rollout_budget_units")
        if container.contains(budgetKey), (try? container.decodeNil(forKey: budgetKey)) != true {
            if let value = try? container.decode(Double.self, forKey: budgetKey), value.isFinite {
                usage.codexRolloutBudgetUnits = value
                usage.coverage?.reportedResponses[.codexRolloutBudgetUnits] = 1
            } else { usage.coverage?.invalidMetrics.insert(.codexRolloutBudgetUnits) }
        }
        assistantUsage = usage
    }
}
