import Foundation

public enum MemoryStoreError: Error, LocalizedError, Equatable, Sendable {
    case invalidNamespace
    case invalidRecord(String)
    case invalidQuery(String)
    case invalidCompaction(String)
    case duplicateRecordID(String)
    case duplicateDedupeKey(String)
    case unsupportedSchemaVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidNamespace:
            return "Memory namespace must not be empty."
        case let .invalidRecord(message):
            return "Invalid memory record: \(message)"
        case let .invalidQuery(message):
            return "Invalid memory query: \(message)"
        case let .invalidCompaction(message):
            return "Invalid memory compaction: \(message)"
        case let .duplicateRecordID(id):
            return "A memory record with id \(id) already exists."
        case let .duplicateDedupeKey(key):
            return "A memory record with dedupe key \(key) already exists."
        case let .unsupportedSchemaVersion(version):
            return "The memory store schema version \(version) is newer than this SDK supports."
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
    public var category: String
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
        category: String,
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
        self.category = category
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

public struct MemoryRecordListQuery: Codable, Hashable, Sendable {
    public var namespace: String
    public var scopes: [MemoryScope]
    public var categories: [String]
    public var includeArchived: Bool
    public var limit: Int?
    public var offset: Int
    public var cursor: MemoryRecordListCursor?

    public init(
        namespace: String,
        scopes: [MemoryScope] = [],
        categories: [String] = [],
        includeArchived: Bool = false,
        limit: Int? = nil,
        offset: Int = 0,
        cursor: MemoryRecordListCursor? = nil
    ) {
        self.namespace = namespace
        self.scopes = scopes
        self.categories = categories
        self.includeArchived = includeArchived
        self.limit = limit
        self.offset = offset
        self.cursor = cursor
    }

    private enum CodingKeys: String, CodingKey {
        case namespace
        case scopes
        case categories
        case includeArchived
        case limit
        case offset
        case cursor
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            namespace: try container.decode(String.self, forKey: .namespace),
            scopes: try container.decodeIfPresent([MemoryScope].self, forKey: .scopes) ?? [],
            categories: try container.decodeIfPresent([String].self, forKey: .categories) ?? [],
            includeArchived: try container.decodeIfPresent(Bool.self, forKey: .includeArchived) ?? false,
            limit: try container.decodeIfPresent(Int.self, forKey: .limit),
            offset: try container.decodeIfPresent(Int.self, forKey: .offset) ?? 0,
            cursor: try container.decodeIfPresent(MemoryRecordListCursor.self, forKey: .cursor)
        )
    }
}

/// Cursor for the list order: effective date descending, then record ID ascending.
public struct MemoryRecordListCursor: Codable, Hashable, Sendable {
    public var effectiveDate: Date
    public var recordID: String

    public init(effectiveDate: Date, recordID: String) {
        self.effectiveDate = effectiveDate
        self.recordID = recordID
    }
}

public struct MemoryStoreDiagnostics: Codable, Hashable, Sendable {
    public var namespace: String
    public var implementation: String
    public var schemaVersion: Int?
    public var totalRecords: Int
    public var activeRecords: Int
    public var archivedRecords: Int
    public var countsByScope: [MemoryScope: Int]
    public var countsByCategory: [String: Int]

    public init(
        namespace: String,
        implementation: String,
        schemaVersion: Int?,
        totalRecords: Int,
        activeRecords: Int,
        archivedRecords: Int,
        countsByScope: [MemoryScope: Int],
        countsByCategory: [String: Int]
    ) {
        self.namespace = namespace
        self.implementation = implementation
        self.schemaVersion = schemaVersion
        self.totalRecords = totalRecords
        self.activeRecords = activeRecords
        self.archivedRecords = archivedRecords
        self.countsByScope = countsByScope
        self.countsByCategory = countsByCategory
    }
}

public struct AgentMemoryContext: Codable, Hashable, Sendable {
    public var namespace: String
    public var scopes: [MemoryScope]
    public var categories: [String]
    public var tags: [String]
    public var relatedIDs: [String]
    public var recencyWindow: TimeInterval?
    public var minImportance: Double?
    public var textMatchPolicy: MemoryTextMatchPolicy?
    public var ranking: MemoryRankingProfile?
    public var readBudget: MemoryReadBudget?

    public init(
        namespace: String,
        scopes: [MemoryScope] = [],
        categories: [String] = [],
        tags: [String] = [],
        relatedIDs: [String] = [],
        recencyWindow: TimeInterval? = nil,
        minImportance: Double? = nil,
        textMatchPolicy: MemoryTextMatchPolicy? = nil,
        ranking: MemoryRankingProfile? = nil,
        readBudget: MemoryReadBudget? = nil
    ) {
        self.namespace = namespace
        self.scopes = scopes
        self.categories = categories
        self.tags = tags
        self.relatedIDs = relatedIDs
        self.recencyWindow = recencyWindow
        self.minImportance = minImportance
        self.textMatchPolicy = textMatchPolicy
        self.ranking = ranking
        self.readBudget = readBudget
    }

    enum CodingKeys: String, CodingKey {
        case namespace
        case scopes
        case categories
        case legacyKinds = "kinds"
        case tags
        case relatedIDs
        case recencyWindow
        case minImportance
        case textMatchPolicy
        case ranking
        case readBudget
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        namespace = try container.decode(String.self, forKey: .namespace)
        scopes = try container.decodeIfPresent([MemoryScope].self, forKey: .scopes) ?? []
        categories =
            try container.decodeIfPresent([String].self, forKey: .categories) ??
            container.decodeIfPresent([String].self, forKey: .legacyKinds) ??
            []
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        relatedIDs = try container.decodeIfPresent([String].self, forKey: .relatedIDs) ?? []
        recencyWindow = try container.decodeIfPresent(TimeInterval.self, forKey: .recencyWindow)
        minImportance = try container.decodeIfPresent(Double.self, forKey: .minImportance)
        textMatchPolicy = try container.decodeIfPresent(
            MemoryTextMatchPolicy.self,
            forKey: .textMatchPolicy
        )
        ranking = try container.decodeIfPresent(MemoryRankingProfile.self, forKey: .ranking)
        readBudget = try container.decodeIfPresent(MemoryReadBudget.self, forKey: .readBudget)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(namespace, forKey: .namespace)
        try container.encode(scopes, forKey: .scopes)
        try container.encode(categories, forKey: .categories)
        try container.encode(tags, forKey: .tags)
        try container.encode(relatedIDs, forKey: .relatedIDs)
        try container.encodeIfPresent(recencyWindow, forKey: .recencyWindow)
        try container.encodeIfPresent(minImportance, forKey: .minImportance)
        try container.encodeIfPresent(textMatchPolicy, forKey: .textMatchPolicy)
        try container.encodeIfPresent(ranking, forKey: .ranking)
        try container.encodeIfPresent(readBudget, forKey: .readBudget)
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
    public var categories: [String]
    public var tags: [String]
    public var relatedIDs: [String]
    public var recencyWindow: TimeInterval?
    public var minImportance: Double?
    public var textMatchPolicy: MemoryTextMatchPolicy?
    public var ranking: MemoryRankingProfile?
    public var readBudget: MemoryReadBudget?
    public var text: String?

    public init(
        mode: MemorySelectionMode = .inherit,
        namespace: String? = nil,
        scopes: [MemoryScope] = [],
        categories: [String] = [],
        tags: [String] = [],
        relatedIDs: [String] = [],
        recencyWindow: TimeInterval? = nil,
        minImportance: Double? = nil,
        textMatchPolicy: MemoryTextMatchPolicy? = nil,
        ranking: MemoryRankingProfile? = nil,
        readBudget: MemoryReadBudget? = nil,
        text: String? = nil
    ) {
        self.mode = mode
        self.namespace = namespace
        self.scopes = scopes
        self.categories = categories
        self.tags = tags
        self.relatedIDs = relatedIDs
        self.recencyWindow = recencyWindow
        self.minImportance = minImportance
        self.textMatchPolicy = textMatchPolicy
        self.ranking = ranking
        self.readBudget = readBudget
        self.text = text
    }
}

public protocol MemoryPromptRendering: Sendable {
    func render(result: MemoryQueryResult, budget: MemoryReadBudget) -> String
}

public enum MemoryObservationEvent: Sendable {
    case queryStarted(MemoryQuery)
    case querySucceeded(query: MemoryQuery, result: MemoryQueryResult)
    case queryFailed(query: MemoryQuery, message: String)
    case captureStarted(threadID: String, sourceDescription: String)
    case captureSucceeded(threadID: String, result: MemoryCaptureResult)
    case captureFailed(threadID: String, message: String)
}

public protocol MemoryObserving: Sendable {
    func handle(event: MemoryObservationEvent) async
}

public enum MemoryAutomaticCaptureSource: Hashable, Sendable {
    case lastTurn
    case threadHistory(maxMessages: Int = 8)
}

public struct MemoryAutomaticCapturePolicy: Sendable {
    public var source: MemoryAutomaticCaptureSource
    public var options: MemoryCaptureOptions
    public var requiresThreadMemoryContext: Bool

    public init(
        source: MemoryAutomaticCaptureSource = .lastTurn,
        options: MemoryCaptureOptions = .init(),
        requiresThreadMemoryContext: Bool = true
    ) {
        self.source = source
        self.options = options
        self.requiresThreadMemoryContext = requiresThreadMemoryContext
    }
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
    public let defaultRanking: MemoryRankingProfile
    public let defaultReadBudget: MemoryReadBudget
    public let promptRenderer: any MemoryPromptRendering
    public let observer: (any MemoryObserving)?
    public let automaticCapturePolicy: MemoryAutomaticCapturePolicy?

    public init(
        store: any MemoryStoring,
        defaultRanking: MemoryRankingProfile = .default,
        defaultReadBudget: MemoryReadBudget = .runtimeDefault,
        promptRenderer: any MemoryPromptRendering = DefaultMemoryPromptRenderer(),
        observer: (any MemoryObserving)? = nil,
        automaticCapturePolicy: MemoryAutomaticCapturePolicy? = nil
    ) {
        self.store = store
        self.defaultRanking = defaultRanking
        self.defaultReadBudget = defaultReadBudget
        self.promptRenderer = promptRenderer
        self.observer = observer
        self.automaticCapturePolicy = automaticCapturePolicy
    }
}
