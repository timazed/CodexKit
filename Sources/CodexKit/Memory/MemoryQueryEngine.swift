import Foundation

internal enum MemoryQueryEngine {
    internal enum TextScoreOrdering {
        case higherIsBetter
        case lowerIsBetter
    }

    internal struct Candidate {
        let record: MemoryRecord
        let textScore: Double?
        let textScoreOrdering: TextScoreOrdering
    }

    private struct ScoredCandidate {
        let match: MemoryQueryMatch
        let characterCost: Int
    }

    static func evaluate(
        candidates: [Candidate],
        query: MemoryQuery,
        now: Date = Date()
    ) throws -> MemoryQueryResult {
        try validateNamespace(query.namespace)

        let activeCandidates = candidates.filter { candidate in
            matchesFilters(candidate.record, query: query, now: now)
        }

        let textScores = normalizedTextScores(from: activeCandidates)

        let scored = activeCandidates.map { candidate -> ScoredCandidate in
            let textScore = textScores[candidate.record.id] ?? 0
            let recencyScore = recencyScore(
                for: candidate.record,
                query: query,
                now: now
            )
            let importanceScore = clamp(candidate.record.importance)
            let kindBoost = query.kinds.contains(candidate.record.kind) ? query.ranking.kindBoost : 0
            let tagBoost = candidate.record.tags.contains(where: query.tags.contains) ? query.ranking.tagBoost : 0
            let relatedBoost = candidate.record.relatedIDs.contains(where: query.relatedIDs.contains) ? query.ranking.relatedIDBoost : 0
            let totalScore =
                (textScore * query.ranking.textWeight) +
                (importanceScore * query.ranking.importanceWeight) +
                (recencyScore * query.ranking.recencyWeight) +
                kindBoost +
                tagBoost +
                relatedBoost

            let explanation = MemoryMatchExplanation(
                totalScore: totalScore,
                textScore: textScore,
                recencyScore: recencyScore,
                importanceScore: importanceScore,
                kindBoost: kindBoost,
                tagBoost: tagBoost,
                relatedIDBoost: relatedBoost
            )
            let match = MemoryQueryMatch(
                record: candidate.record,
                explanation: explanation
            )

            return ScoredCandidate(
                match: match,
                characterCost: renderMatch(match).count
            )
        }
        .sorted {
            if $0.match.explanation.totalScore == $1.match.explanation.totalScore {
                if $0.match.record.effectiveDate == $1.match.record.effectiveDate {
                    return $0.match.record.id < $1.match.record.id
                }
                return $0.match.record.effectiveDate > $1.match.record.effectiveDate
            }
            return $0.match.explanation.totalScore > $1.match.explanation.totalScore
        }

        var selected: [MemoryQueryMatch] = []
        var characterCount = 0
        var truncated = false

        for candidate in scored {
            if selected.count >= query.limit {
                truncated = true
                break
            }

            let nextCount = characterCount + candidate.characterCost + (selected.isEmpty ? 0 : 1)
            if nextCount > query.maxCharacters {
                truncated = true
                continue
            }

            selected.append(candidate.match)
            characterCount = nextCount
        }

        if !truncated {
            truncated = selected.count < scored.count
        }

        return MemoryQueryResult(
            matches: selected,
            truncated: truncated
        )
    }

    static func renderPrompt(
        matches: [MemoryQueryMatch],
        budget: MemoryReadBudget
    ) -> String {
        var lines: [String] = []
        var characterCount = 0

        for match in matches.prefix(budget.maxItems) {
            let rendered = renderMatch(match)
            let nextCount = characterCount + rendered.count + (lines.isEmpty ? 0 : 1)
            if !lines.isEmpty, nextCount > budget.maxCharacters {
                break
            }
            if lines.isEmpty, rendered.count > budget.maxCharacters {
                break
            }
            lines.append(rendered)
            characterCount = nextCount
        }

        guard !lines.isEmpty else {
            return ""
        }

        return """
        Relevant Memory:
        \(lines.joined(separator: "\n"))
        """
    }

    static func defaultTextScore(
        for record: MemoryRecord,
        queryText: String?
    ) -> Double {
        let queryTokens = tokenize(queryText)
        guard !queryTokens.isEmpty else {
            return 0
        }

        let haystack = tokenize(
            ([record.summary] + record.evidence + record.tags + [record.kind]).joined(separator: " ")
        )
        guard !haystack.isEmpty else {
            return 0
        }

        let overlap = Set(queryTokens).intersection(Set(haystack))
        return Double(overlap.count) / Double(Set(queryTokens).count)
    }

    static func validateNamespace(_ namespace: String) throws {
        guard !namespace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MemoryStoreError.invalidNamespace
        }
    }

    static func tokenize(_ value: String?) -> [String] {
        guard let value else {
            return []
        }

        return value
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private static func matchesFilters(
        _ record: MemoryRecord,
        query: MemoryQuery,
        now: Date
    ) -> Bool {
        guard record.namespace == query.namespace else {
            return false
        }

        if !query.includeArchived, record.status == .archived {
            return false
        }

        if !record.isPinned,
           let expiresAt = record.expiresAt,
           expiresAt <= now {
            return false
        }

        if !query.scopes.isEmpty, !query.scopes.contains(record.scope) {
            return false
        }

        if !query.kinds.isEmpty, !query.kinds.contains(record.kind) {
            return false
        }

        if !query.tags.isEmpty, !record.tags.contains(where: query.tags.contains) {
            return false
        }

        if !query.relatedIDs.isEmpty, !record.relatedIDs.contains(where: query.relatedIDs.contains) {
            return false
        }

        if let minImportance = query.minImportance,
           clamp(record.importance) < minImportance {
            return false
        }

        if let recencyWindow = query.recencyWindow,
           now.timeIntervalSince(record.effectiveDate) > recencyWindow {
            return false
        }

        return true
    }

    private static func normalizedTextScores(
        from candidates: [Candidate]
    ) -> [String: Double] {
        let rawScores = candidates.compactMap(\.textScore)
        guard let maxScore = rawScores.max(),
              let minScore = rawScores.min()
        else {
            return [:]
        }

        return candidates.reduce(into: [String: Double]()) { partial, candidate in
            guard let rawScore = candidate.textScore else {
                partial[candidate.record.id] = 0
                return
            }

            if maxScore == minScore {
                switch candidate.textScoreOrdering {
                case .higherIsBetter:
                    partial[candidate.record.id] = rawScore > 0 ? 1 : 0
                case .lowerIsBetter:
                    partial[candidate.record.id] = 1
                }
            } else {
                switch candidate.textScoreOrdering {
                case .higherIsBetter:
                    partial[candidate.record.id] = clamp((rawScore - minScore) / (maxScore - minScore))
                case .lowerIsBetter:
                    partial[candidate.record.id] = clamp((maxScore - rawScore) / (maxScore - minScore))
                }
            }
        }
    }

    private static func recencyScore(
        for record: MemoryRecord,
        query: MemoryQuery,
        now: Date
    ) -> Double {
        let halfLife = max(query.recencyWindow ?? (30 * 24 * 60 * 60), 1)
        let age = max(now.timeIntervalSince(record.effectiveDate), 0)
        return clamp(pow(0.5, age / halfLife))
    }

    private static func renderMatch(_ match: MemoryQueryMatch) -> String {
        var components: [String] = [
            "- [\(match.record.scope.rawValue)] [\(match.record.kind)] \(match.record.summary)"
        ]

        if let evidence = match.record.evidence.first,
           !evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            components.append("  Evidence: \(evidence)")
        }

        if !match.record.tags.isEmpty {
            components.append("  Tags: \(match.record.tags.joined(separator: ", "))")
        }

        return components.joined(separator: "\n")
    }

    private static func clamp(_ value: Double) -> Double {
        min(1, max(0, value))
    }
}
