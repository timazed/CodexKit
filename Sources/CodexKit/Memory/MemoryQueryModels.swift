import Foundation

/// A portable ordering contract implemented identically by every memory store.
/// Text and structural criteria decide eligibility; this profile decides order.
public enum MemoryRankingProfile: String, Codable, Hashable, Sendable {
    case importanceThenRecency
    case recencyThenImportance

    public static let `default`: Self = .importanceThenRecency

    private enum LegacyCodingKeys: String, CodingKey {
        case importanceWeight
        case recencyWeight
    }

    public init(from decoder: any Decoder) throws {
        if let rawValue = try? decoder.singleValueContainer().decode(String.self),
           let value = Self(rawValue: rawValue) {
            self = value
            return
        }
        let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
        let importance = try legacy.decodeIfPresent(Double.self, forKey: .importanceWeight) ?? 0
        let recency = try legacy.decodeIfPresent(Double.self, forKey: .recencyWeight) ?? 0
        self = recency > importance ? .recencyThenImportance : .importanceThenRecency
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Controls how many distinct query tokens a record must contain. Text matching
/// remains an eligibility predicate and never silently changes the ranking profile.
public enum MemoryTextMatchPolicy: Codable, Hashable, Sendable {
    case anyToken
    case atLeastTokens(Int)
    case allTokens

    public static let runtimeDefault: Self = .atLeastTokens(2)

    private enum CodingKeys: String, CodingKey {
        case mode
        case count
    }

    private enum Mode: String, Codable {
        case anyToken
        case atLeastTokens
        case allTokens
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Mode.self, forKey: .mode) {
        case .anyToken:
            self = .anyToken
        case .atLeastTokens:
            self = .atLeastTokens(try container.decode(Int.self, forKey: .count))
        case .allTokens:
            self = .allTokens
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .anyToken:
            try container.encode(Mode.anyToken, forKey: .mode)
        case let .atLeastTokens(count):
            try container.encode(Mode.atLeastTokens, forKey: .mode)
            try container.encode(count, forKey: .count)
        case .allTokens:
            try container.encode(Mode.allTokens, forKey: .mode)
        }
    }
}

public struct MemoryReadBudget: Codable, Hashable, Sendable {
    public var maxItems: Int
    public var maxCharacters: Int

    public init(maxItems: Int, maxCharacters: Int) {
        self.maxItems = maxItems
        self.maxCharacters = maxCharacters
    }

    public static let runtimeDefault = MemoryReadBudget(maxItems: 8, maxCharacters: 1600)
}

/// Keyset cursor over the deterministic memory ranking order.
public struct MemoryQueryCursor: Codable, Hashable, Sendable {
    public let namespace: String
    public let rankingProfile: MemoryRankingProfile
    public let importance: Double
    public let effectiveDate: Date
    public let recordOrder: Int64
    public let recordID: String

    public init(
        namespace: String,
        rankingProfile: MemoryRankingProfile,
        importance: Double,
        effectiveDate: Date,
        recordOrder: Int64,
        recordID: String
    ) {
        self.namespace = namespace
        self.rankingProfile = rankingProfile
        self.importance = importance
        self.effectiveDate = effectiveDate
        self.recordOrder = recordOrder
        self.recordID = recordID
    }
}

public struct MemoryQuery: Codable, Hashable, Sendable {
    public var namespace: String
    public var scopes: [MemoryScope]
    public var text: String?
    public var textMatchPolicy: MemoryTextMatchPolicy
    public var categories: [String]
    public var tags: [String]
    public var relatedIDs: [String]
    public var recencyWindow: TimeInterval?
    public var minImportance: Double?
    public var ranking: MemoryRankingProfile
    public var limit: Int
    /// Aggregate rendered-character budget for the deterministic ranked prefix
    /// returned by the store.
    public var maxCharacters: Int
    public var includeArchived: Bool
    public var cursor: MemoryQueryCursor?

    public init(
        namespace: String,
        scopes: [MemoryScope] = [],
        text: String? = nil,
        textMatchPolicy: MemoryTextMatchPolicy = .anyToken,
        categories: [String] = [],
        tags: [String] = [],
        relatedIDs: [String] = [],
        recencyWindow: TimeInterval? = nil,
        minImportance: Double? = nil,
        ranking: MemoryRankingProfile = .default,
        limit: Int = MemoryReadBudget.runtimeDefault.maxItems,
        maxCharacters: Int = MemoryReadBudget.runtimeDefault.maxCharacters,
        includeArchived: Bool = false,
        cursor: MemoryQueryCursor? = nil
    ) {
        self.namespace = namespace
        self.scopes = scopes
        self.text = text
        self.textMatchPolicy = textMatchPolicy
        self.categories = categories
        self.tags = tags
        self.relatedIDs = relatedIDs
        self.recencyWindow = recencyWindow
        self.minImportance = minImportance
        self.ranking = ranking
        self.limit = limit
        self.maxCharacters = maxCharacters
        self.includeArchived = includeArchived
        self.cursor = cursor
    }

    private enum CodingKeys: String, CodingKey {
        case namespace, scopes, text, textMatchPolicy, categories, tags, relatedIDs
        case recencyWindow, minImportance, ranking, limit, maxCharacters, includeArchived, cursor
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            namespace: try container.decode(String.self, forKey: .namespace),
            scopes: try container.decodeIfPresent([MemoryScope].self, forKey: .scopes) ?? [],
            text: try container.decodeIfPresent(String.self, forKey: .text),
            textMatchPolicy: try container.decodeIfPresent(
                MemoryTextMatchPolicy.self,
                forKey: .textMatchPolicy
            ) ?? .anyToken,
            categories: try container.decodeIfPresent([String].self, forKey: .categories) ?? [],
            tags: try container.decodeIfPresent([String].self, forKey: .tags) ?? [],
            relatedIDs: try container.decodeIfPresent([String].self, forKey: .relatedIDs) ?? [],
            recencyWindow: try container.decodeIfPresent(TimeInterval.self, forKey: .recencyWindow),
            minImportance: try container.decodeIfPresent(Double.self, forKey: .minImportance),
            ranking: try container.decodeIfPresent(MemoryRankingProfile.self, forKey: .ranking) ?? .default,
            limit: try container.decodeIfPresent(Int.self, forKey: .limit) ?? MemoryReadBudget.runtimeDefault.maxItems,
            maxCharacters: try container.decodeIfPresent(Int.self, forKey: .maxCharacters) ?? MemoryReadBudget.runtimeDefault.maxCharacters,
            includeArchived: try container.decodeIfPresent(Bool.self, forKey: .includeArchived) ?? false,
            cursor: try container.decodeIfPresent(MemoryQueryCursor.self, forKey: .cursor)
        )
    }
}

public enum MemoryQueryExecutionMethod: String, Codable, Hashable, Sendable {
    case inMemory
    case databaseNative
}

public struct MemoryMatchExplanation: Codable, Hashable, Sendable {
    public var rankingProfile: MemoryRankingProfile
    public var executionMethod: MemoryQueryExecutionMethod
    public var matchedTokenCount: Int
    public var queryTokenCount: Int
    public var recencyScore: Double
    public var importanceScore: Double

    public init(
        rankingProfile: MemoryRankingProfile,
        executionMethod: MemoryQueryExecutionMethod,
        matchedTokenCount: Int,
        queryTokenCount: Int,
        recencyScore: Double,
        importanceScore: Double
    ) {
        self.rankingProfile = rankingProfile
        self.executionMethod = executionMethod
        self.matchedTokenCount = matchedTokenCount
        self.queryTokenCount = queryTokenCount
        self.recencyScore = recencyScore
        self.importanceScore = importanceScore
    }

    public var textCoverage: Double {
        guard queryTokenCount > 0 else { return 0 }
        return Double(matchedTokenCount) / Double(queryTokenCount)
    }

    private enum CodingKeys: String, CodingKey {
        case rankingProfile, executionMethod, matchedTokenCount, queryTokenCount
        case recencyScore, importanceScore
        case legacyRankingMethod = "rankingMethod"
        case legacyTextScore = "textScore"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let legacyMethod = try container.decodeIfPresent(
            LegacyMemoryRankingMethod.self,
            forKey: .legacyRankingMethod
        )
        let legacyTextScore = try container.decodeIfPresent(
            Double.self,
            forKey: .legacyTextScore
        ) ?? 0
        self.init(
            rankingProfile: try container.decodeIfPresent(
                MemoryRankingProfile.self,
                forKey: .rankingProfile
            ) ?? .default,
            executionMethod: try container.decodeIfPresent(
                MemoryQueryExecutionMethod.self,
                forKey: .executionMethod
            ) ?? (legacyMethod?.isDatabaseNative == true ? .databaseNative : .inMemory),
            matchedTokenCount: try container.decodeIfPresent(
                Int.self,
                forKey: .matchedTokenCount
            ) ?? (legacyTextScore > 0 ? 1 : 0),
            queryTokenCount: try container.decodeIfPresent(
                Int.self,
                forKey: .queryTokenCount
            ) ?? (legacyTextScore > 0 ? 1 : 0),
            recencyScore: try container.decode(Double.self, forKey: .recencyScore),
            importanceScore: try container.decode(Double.self, forKey: .importanceScore)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rankingProfile, forKey: .rankingProfile)
        try container.encode(executionMethod, forKey: .executionMethod)
        try container.encode(matchedTokenCount, forKey: .matchedTokenCount)
        try container.encode(queryTokenCount, forKey: .queryTokenCount)
        try container.encode(recencyScore, forKey: .recencyScore)
        try container.encode(importanceScore, forKey: .importanceScore)
    }
}

private enum LegacyMemoryRankingMethod: String, Codable {
    case weightedScore
    case portableProfile
    case databaseNative
    case realmNativeTiered
    case databaseNativeTiered

    var isDatabaseNative: Bool {
        switch self {
        case .databaseNative, .realmNativeTiered, .databaseNativeTiered:
            true
        case .weightedScore, .portableProfile:
            false
        }
    }
}

public struct MemoryQueryMatch: Codable, Hashable, Sendable {
    public var record: MemoryRecord
    public var explanation: MemoryMatchExplanation

    public init(record: MemoryRecord, explanation: MemoryMatchExplanation) {
        self.record = record
        self.explanation = explanation
    }
}

public struct MemoryQueryResult: Codable, Hashable, Sendable {
    public var matches: [MemoryQueryMatch]
    public var truncated: Bool
    public var nextCursor: MemoryQueryCursor?

    public init(
        matches: [MemoryQueryMatch],
        truncated: Bool,
        nextCursor: MemoryQueryCursor? = nil
    ) {
        self.matches = matches
        self.truncated = truncated
        self.nextCursor = nextCursor
    }
}
