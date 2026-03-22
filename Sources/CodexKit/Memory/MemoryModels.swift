import Foundation

public enum MemoryStoreError: Error, LocalizedError, Equatable, Sendable {
    case invalidNamespace
    case duplicateRecordID(String)
    case duplicateDedupeKey(String)

    public var errorDescription: String? {
        switch self {
        case .invalidNamespace:
            return "Memory namespace must not be empty."
        case let .duplicateRecordID(id):
            return "A memory record with id \(id) already exists."
        case let .duplicateDedupeKey(key):
            return "A memory record with dedupe key \(key) already exists."
        }
    }
}

public struct MemoryScope: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: StringLiteralType) {
        self.init(rawValue: value)
    }
}

public enum MemoryRecordStatus: String, Codable, Hashable, Sendable {
    case active
    case archived
}

public struct MemoryRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var namespace: String
    public var scope: MemoryScope
    public var kind: String
    public var summary: String
    public var evidence: [String]
    public var importance: Double
    public var createdAt: Date
    public var observedAt: Date?
    public var expiresAt: Date?
    public var tags: [String]
    public var relatedIDs: [String]
    public var dedupeKey: String?
    public var isPinned: Bool
    public var attributes: JSONValue?
    public var status: MemoryRecordStatus

    public init(
        id: String = UUID().uuidString,
        namespace: String,
        scope: MemoryScope,
        kind: String,
        summary: String,
        evidence: [String] = [],
        importance: Double = 0,
        createdAt: Date = Date(),
        observedAt: Date? = nil,
        expiresAt: Date? = nil,
        tags: [String] = [],
        relatedIDs: [String] = [],
        dedupeKey: String? = nil,
        isPinned: Bool = false,
        attributes: JSONValue? = nil,
        status: MemoryRecordStatus = .active
    ) {
        self.id = id
        self.namespace = namespace
        self.scope = scope
        self.kind = kind
        self.summary = summary
        self.evidence = evidence
        self.importance = importance
        self.createdAt = createdAt
        self.observedAt = observedAt
        self.expiresAt = expiresAt
        self.tags = tags
        self.relatedIDs = relatedIDs
        self.dedupeKey = dedupeKey
        self.isPinned = isPinned
        self.attributes = attributes
        self.status = status
    }

    public var effectiveDate: Date {
        observedAt ?? createdAt
    }
}

public struct MemoryRankingWeights: Codable, Hashable, Sendable {
    public var textWeight: Double
    public var importanceWeight: Double
    public var recencyWeight: Double
    public var kindBoost: Double
    public var tagBoost: Double
    public var relatedIDBoost: Double

    public init(
        textWeight: Double,
        importanceWeight: Double,
        recencyWeight: Double,
        kindBoost: Double,
        tagBoost: Double,
        relatedIDBoost: Double
    ) {
        self.textWeight = textWeight
        self.importanceWeight = importanceWeight
        self.recencyWeight = recencyWeight
        self.kindBoost = kindBoost
        self.tagBoost = tagBoost
        self.relatedIDBoost = relatedIDBoost
    }

    public static let `default` = MemoryRankingWeights(
        textWeight: 0.50,
        importanceWeight: 0.25,
        recencyWeight: 0.15,
        kindBoost: 0.05,
        tagBoost: 0.03,
        relatedIDBoost: 0.02
    )
}

public struct MemoryReadBudget: Codable, Hashable, Sendable {
    public var maxItems: Int
    public var maxCharacters: Int

    public init(
        maxItems: Int,
        maxCharacters: Int
    ) {
        self.maxItems = maxItems
        self.maxCharacters = maxCharacters
    }

    public static let runtimeDefault = MemoryReadBudget(
        maxItems: 8,
        maxCharacters: 1600
    )
}

public struct MemoryQuery: Codable, Hashable, Sendable {
    public var namespace: String
    public var scopes: [MemoryScope]
    public var text: String?
    public var kinds: [String]
    public var tags: [String]
    public var relatedIDs: [String]
    public var recencyWindow: TimeInterval?
    public var minImportance: Double?
    public var ranking: MemoryRankingWeights
    public var limit: Int
    public var maxCharacters: Int
    public var includeArchived: Bool

    public init(
        namespace: String,
        scopes: [MemoryScope] = [],
        text: String? = nil,
        kinds: [String] = [],
        tags: [String] = [],
        relatedIDs: [String] = [],
        recencyWindow: TimeInterval? = nil,
        minImportance: Double? = nil,
        ranking: MemoryRankingWeights = .default,
        limit: Int = MemoryReadBudget.runtimeDefault.maxItems,
        maxCharacters: Int = MemoryReadBudget.runtimeDefault.maxCharacters,
        includeArchived: Bool = false
    ) {
        self.namespace = namespace
        self.scopes = scopes
        self.text = text
        self.kinds = kinds
        self.tags = tags
        self.relatedIDs = relatedIDs
        self.recencyWindow = recencyWindow
        self.minImportance = minImportance
        self.ranking = ranking
        self.limit = limit
        self.maxCharacters = maxCharacters
        self.includeArchived = includeArchived
    }
}

public struct MemoryMatchExplanation: Codable, Hashable, Sendable {
    public var totalScore: Double
    public var textScore: Double
    public var recencyScore: Double
    public var importanceScore: Double
    public var kindBoost: Double
    public var tagBoost: Double
    public var relatedIDBoost: Double

    public init(
        totalScore: Double,
        textScore: Double,
        recencyScore: Double,
        importanceScore: Double,
        kindBoost: Double,
        tagBoost: Double,
        relatedIDBoost: Double
    ) {
        self.totalScore = totalScore
        self.textScore = textScore
        self.recencyScore = recencyScore
        self.importanceScore = importanceScore
        self.kindBoost = kindBoost
        self.tagBoost = tagBoost
        self.relatedIDBoost = relatedIDBoost
    }
}

public struct MemoryQueryMatch: Codable, Hashable, Sendable {
    public var record: MemoryRecord
    public var explanation: MemoryMatchExplanation

    public init(
        record: MemoryRecord,
        explanation: MemoryMatchExplanation
    ) {
        self.record = record
        self.explanation = explanation
    }
}

public struct MemoryQueryResult: Codable, Hashable, Sendable {
    public var matches: [MemoryQueryMatch]
    public var truncated: Bool

    public init(
        matches: [MemoryQueryMatch],
        truncated: Bool
    ) {
        self.matches = matches
        self.truncated = truncated
    }
}

public struct MemoryCompactionRequest: Codable, Hashable, Sendable {
    public var replacement: MemoryRecord
    public var sourceIDs: [String]

    public init(
        replacement: MemoryRecord,
        sourceIDs: [String]
    ) {
        self.replacement = replacement
        self.sourceIDs = sourceIDs
    }
}

public struct AgentMemoryContext: Codable, Hashable, Sendable {
    public var namespace: String
    public var scopes: [MemoryScope]
    public var kinds: [String]
    public var tags: [String]
    public var relatedIDs: [String]
    public var recencyWindow: TimeInterval?
    public var minImportance: Double?
    public var ranking: MemoryRankingWeights?
    public var readBudget: MemoryReadBudget?

    public init(
        namespace: String,
        scopes: [MemoryScope] = [],
        kinds: [String] = [],
        tags: [String] = [],
        relatedIDs: [String] = [],
        recencyWindow: TimeInterval? = nil,
        minImportance: Double? = nil,
        ranking: MemoryRankingWeights? = nil,
        readBudget: MemoryReadBudget? = nil
    ) {
        self.namespace = namespace
        self.scopes = scopes
        self.kinds = kinds
        self.tags = tags
        self.relatedIDs = relatedIDs
        self.recencyWindow = recencyWindow
        self.minImportance = minImportance
        self.ranking = ranking
        self.readBudget = readBudget
    }
}

public enum MemorySelectionMode: String, Codable, Hashable, Sendable {
    case inherit
    case append
    case replace
    case disable
}

public struct MemorySelection: Codable, Hashable, Sendable {
    public var mode: MemorySelectionMode
    public var namespace: String?
    public var scopes: [MemoryScope]
    public var kinds: [String]
    public var tags: [String]
    public var relatedIDs: [String]
    public var recencyWindow: TimeInterval?
    public var minImportance: Double?
    public var ranking: MemoryRankingWeights?
    public var readBudget: MemoryReadBudget?
    public var text: String?

    public init(
        mode: MemorySelectionMode = .inherit,
        namespace: String? = nil,
        scopes: [MemoryScope] = [],
        kinds: [String] = [],
        tags: [String] = [],
        relatedIDs: [String] = [],
        recencyWindow: TimeInterval? = nil,
        minImportance: Double? = nil,
        ranking: MemoryRankingWeights? = nil,
        readBudget: MemoryReadBudget? = nil,
        text: String? = nil
    ) {
        self.mode = mode
        self.namespace = namespace
        self.scopes = scopes
        self.kinds = kinds
        self.tags = tags
        self.relatedIDs = relatedIDs
        self.recencyWindow = recencyWindow
        self.minImportance = minImportance
        self.ranking = ranking
        self.readBudget = readBudget
        self.text = text
    }
}

public protocol MemoryPromptRendering: Sendable {
    func render(result: MemoryQueryResult, budget: MemoryReadBudget) -> String
}

public struct DefaultMemoryPromptRenderer: MemoryPromptRendering, Sendable {
    public init() {}

    public func render(
        result: MemoryQueryResult,
        budget: MemoryReadBudget
    ) -> String {
        MemoryQueryEngine.renderPrompt(
            matches: result.matches,
            budget: budget
        )
    }
}

public struct AgentMemoryConfiguration: Sendable {
    public let store: any MemoryStoring
    public let defaultRanking: MemoryRankingWeights
    public let defaultReadBudget: MemoryReadBudget
    public let promptRenderer: any MemoryPromptRendering

    public init(
        store: any MemoryStoring,
        defaultRanking: MemoryRankingWeights = .default,
        defaultReadBudget: MemoryReadBudget = .runtimeDefault,
        promptRenderer: any MemoryPromptRendering = DefaultMemoryPromptRenderer()
    ) {
        self.store = store
        self.defaultRanking = defaultRanking
        self.defaultReadBudget = defaultReadBudget
        self.promptRenderer = promptRenderer
    }
}
