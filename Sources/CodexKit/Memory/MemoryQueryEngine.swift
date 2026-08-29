import Foundation

package enum MemoryQueryEngine {
    private static let promptHeader = "Relevant Memory:\n"

    package struct Candidate {
        package let record: MemoryRecord
        package let matchedTokenCount: Int
        package let queryTokenCount: Int

        package init(
            record: MemoryRecord,
            matchedTokenCount: Int,
            queryTokenCount: Int
        ) {
            self.record = record
            self.matchedTokenCount = matchedTokenCount
            self.queryTokenCount = queryTokenCount
        }
    }

    private struct ScoredCandidate {
        let match: MemoryQueryMatch
        let characterCost: Int
    }

    package static func evaluate(
        candidates: [Candidate],
        query: MemoryQuery,
        now: Date = Date()
    ) throws -> MemoryQueryResult {
        try validate(query)

        let queryTokenCount = uniqueTokens(query.text).count
        let minimumTextMatches = requiredTextMatchCount(
            policy: query.textMatchPolicy,
            queryTokenCount: queryTokenCount
        )
        let activeCandidates = candidates.filter { candidate in
            matchesFilters(candidate.record, query: query, now: now) &&
                candidate.matchedTokenCount >= minimumTextMatches
        }

        let scored = activeCandidates.map { candidate -> ScoredCandidate in
            let match = makeMatch(
                record: candidate.record,
                query: query,
                now: now,
                matchedTokenCount: candidate.matchedTokenCount,
                queryTokenCount: candidate.queryTokenCount,
                executionMethod: .inMemory
            )
            return ScoredCandidate(
                match: match,
                characterCost: renderedCharacterCount(for: candidate.record)
            )
        }
        .sorted { lhs, rhs in
            ordered(lhs.match.record, before: rhs.match.record, profile: query.ranking)
        }

        let individuallyRenderable = scored.filter {
            $0.characterCost <= query.maxCharacters
        }
        let paged = individuallyRenderable.filter {
            guard let cursor = query.cursor else { return true }
            return isAfterCursor($0.match.record, cursor: cursor, profile: query.ranking)
        }
        var selected: [MemoryQueryMatch] = []
        var characterCount = 0
        for candidate in paged {
            guard selected.count < max(0, query.limit) else { break }
            let separatorCost = selected.isEmpty ? 0 : 1
            let remaining = query.maxCharacters - characterCount
            guard separatorCost <= remaining,
                  candidate.characterCost <= remaining - separatorCost else {
                break
            }
            selected.append(candidate.match)
            characterCount += candidate.characterCost + separatorCost
        }
        let truncated = selected.count < paged.count

        return MemoryQueryResult(
            matches: selected,
            truncated: truncated,
            nextCursor: truncated ? selected.last.map { cursor(for: $0.record, query: query) } : nil
        )
    }

    package static func renderPrompt(
        matches: [MemoryQueryMatch],
        budget: MemoryReadBudget
    ) -> String {
        var lines: [String] = []
        var characterCount = 0

        let itemLimit = max(0, budget.maxItems)
        let characterLimit = promptContentCharacterLimit(for: budget)
        for match in matches {
            guard lines.count < itemLimit else { break }
            let rendered = renderMatch(match)
            let separatorCost = lines.isEmpty ? 0 : 1
            let remaining = characterLimit - characterCount
            guard separatorCost <= remaining,
                  rendered.count <= remaining - separatorCost
            else {
                continue
            }
            lines.append(rendered)
            characterCount += rendered.count + separatorCost
        }

        guard !lines.isEmpty else {
            return ""
        }

        return promptHeader + lines.joined(separator: "\n")
    }

    package static func promptContentCharacterLimit(for budget: MemoryReadBudget) -> Int {
        guard budget.maxCharacters > promptHeader.count else {
            return 0
        }
        return budget.maxCharacters - promptHeader.count
    }

    package static func matchedTokenCount(
        for record: MemoryRecord,
        queryTokens: Set<String>
    ) -> Int {
        guard !queryTokens.isEmpty else { return 0 }
        let recordTokens = Set(tokenize(
            ([record.summary] + record.evidence + record.tags + [record.category]).joined(separator: " ")
        ))
        return queryTokens.intersection(recordTokens).count
    }

    package static func uniqueTokens(_ value: String?) -> [String] {
        tokenize(
            value,
            maximumTokenCount: MemoryStoreLimits.maximumQueryTokenCount,
            maximumInputBytes: MemoryStoreLimits.maximumQueryTextByteCount
        )
    }

    package static func requiredTextMatchCount(
        policy: MemoryTextMatchPolicy,
        queryTokenCount: Int
    ) -> Int {
        guard queryTokenCount > 0 else { return 0 }
        switch policy {
        case .anyToken:
            return 1
        case let .atLeastTokens(count):
            return count
        case .allTokens:
            return queryTokenCount
        }
    }

    /// Builds the public explanation for a record which has already been
    /// selected and ordered by a persistent store. Persistent stores use this
    /// helper only for the bounded result window; it must not be used to sort
    /// an unbounded database candidate set in Swift.
    package static func makeMatch(
        record: MemoryRecord,
        query: MemoryQuery,
        now: Date,
        matchedTokenCount: Int,
        queryTokenCount: Int,
        executionMethod: MemoryQueryExecutionMethod = .inMemory
    ) -> MemoryQueryMatch {
        let recencyScore = recencyScore(for: record, query: query, now: now)
        let importanceScore = clamp(record.importance)

        return MemoryQueryMatch(
            record: record,
            explanation: MemoryMatchExplanation(
                rankingProfile: query.ranking,
                executionMethod: executionMethod,
                matchedTokenCount: matchedTokenCount,
                queryTokenCount: queryTokenCount,
                recencyScore: recencyScore,
                importanceScore: importanceScore
            )
        )
    }

    package static func renderedCharacterCount(for record: MemoryRecord) -> Int {
        renderMatch(MemoryQueryMatch(
            record: record,
            explanation: MemoryMatchExplanation(
                rankingProfile: .default,
                executionMethod: .inMemory,
                matchedTokenCount: 0,
                queryTokenCount: 0,
                recencyScore: 0,
                importanceScore: 0
            )
        )).count
    }

    /// Stable adapter-independent numeric tie breaker. Persistent stores index
    /// this value so equal importance/date groups do not require a full string
    /// sort. The record ID remains the final collision tie breaker.
    package static func recordOrder(for id: String) -> Int64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in id.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return Int64(bitPattern: hash)
    }

    package static func cursor(
        for record: MemoryRecord,
        query: MemoryQuery
    ) -> MemoryQueryCursor {
        MemoryQueryCursor(
            namespace: query.namespace,
            rankingProfile: query.ranking,
            importance: record.importance,
            effectiveDate: record.effectiveDate,
            recordOrder: recordOrder(for: record.id),
            recordID: record.id
        )
    }

    package static func isAfterCursor(
        _ record: MemoryRecord,
        cursor: MemoryQueryCursor,
        profile: MemoryRankingProfile
    ) -> Bool {
        let order = recordOrder(for: record.id)
        switch profile {
        case .importanceThenRecency:
            if record.importance != cursor.importance {
                return record.importance < cursor.importance
            }
            if record.effectiveDate != cursor.effectiveDate {
                return record.effectiveDate < cursor.effectiveDate
            }
        case .recencyThenImportance:
            if record.effectiveDate != cursor.effectiveDate {
                return record.effectiveDate < cursor.effectiveDate
            }
            if record.importance != cursor.importance {
                return record.importance < cursor.importance
            }
        }
        if order != cursor.recordOrder {
            return order > cursor.recordOrder
        }
        return record.id > cursor.recordID
    }

    /// Realm cannot index Double columns. Canonicalizing signed zero keeps the
    /// indexed representation consistent with Swift and SQLite equality/order.
    package static func importanceRank(for importance: Double) -> Int64 {
        let canonical = importance == 0 ? 0.0 : importance
        return Int64(bitPattern: canonical.bitPattern)
    }

    /// Tokenizes a bounded prefix and stops as soon as the requested number of
    /// distinct tokens has been collected. Oversized tokens are ignored rather
    /// than being truncated into potentially colliding database keys.
    package static func tokenize(
        _ value: String?,
        maximumTokenCount: Int = MemoryStoreLimits.maximumStoredSearchTokenCount,
        maximumInputBytes: Int = MemoryStoreLimits.maximumSearchableRecordByteCount
    ) -> [String] {
        guard let value, maximumTokenCount > 0, maximumInputBytes > 0 else {
            return []
        }
        let bounded = String(
            decoding: value.utf8.prefix(maximumInputBytes),
            as: UTF8.self
        )
        let normalized = bounded
            .precomposedStringWithCanonicalMapping
            .lowercased()
        var result: [String] = []
        var seen = Set<String>()
        var token = ""
        var tokenByteCount = 0
        var oversized = false

        func appendToken() -> Bool {
            defer {
                token.removeAll(keepingCapacity: true)
                tokenByteCount = 0
                oversized = false
            }
            guard !token.isEmpty, !oversized, seen.insert(token).inserted else {
                return false
            }
            result.append(token)
            return result.count == maximumTokenCount
        }

        for character in normalized {
            if character.isLetter || character.isNumber {
                let bytes = character.utf8.count
                if tokenByteCount + bytes <= MemoryStoreLimits.maximumTokenByteCount {
                    token.append(character)
                    tokenByteCount += bytes
                } else {
                    oversized = true
                }
            } else if appendToken() {
                break
            }
        }
        if result.count < maximumTokenCount {
            _ = appendToken()
        }
        return result.sorted()
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

        if !query.categories.isEmpty, !query.categories.contains(record.category) {
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

    package static func ordered(
        _ lhs: MemoryRecord,
        before rhs: MemoryRecord,
        profile: MemoryRankingProfile
    ) -> Bool {
        switch profile {
        case .importanceThenRecency:
            if lhs.importance != rhs.importance {
                return lhs.importance > rhs.importance
            }
            if lhs.effectiveDate != rhs.effectiveDate {
                return lhs.effectiveDate > rhs.effectiveDate
            }
        case .recencyThenImportance:
            if lhs.effectiveDate != rhs.effectiveDate {
                return lhs.effectiveDate > rhs.effectiveDate
            }
            if lhs.importance != rhs.importance {
                return lhs.importance > rhs.importance
            }
        }
        let lhsOrder = recordOrder(for: lhs.id)
        let rhsOrder = recordOrder(for: rhs.id)
        if lhsOrder != rhsOrder {
            return lhsOrder < rhsOrder
        }
        return lhs.id < rhs.id
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
            "- [\(match.record.scope.rawValue)] [\(match.record.category)] \(match.record.summary)"
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
