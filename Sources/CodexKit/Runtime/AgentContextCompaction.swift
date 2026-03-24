import Foundation

public enum AgentContextCompactionMode: String, Codable, Hashable, Sendable {
    case manual
    case automatic

    var supportsManual: Bool {
        true
    }

    var supportsAutomatic: Bool {
        self == .automatic
    }
}

public enum AgentContextCompactionVisibility: String, Codable, Hashable, Sendable {
    case hidden
    case debugVisible
}

public enum AgentContextCompactionStrategy: String, Codable, Hashable, Sendable {
    case preferRemoteThenLocal
    case remoteOnly
    case localOnly
}

public struct AgentContextCompactionTrigger: Codable, Hashable, Sendable {
    public var estimatedTokenThreshold: Int
    public var retryOnContextLimitError: Bool

    public init(
        estimatedTokenThreshold: Int = 16_000,
        retryOnContextLimitError: Bool = true
    ) {
        self.estimatedTokenThreshold = estimatedTokenThreshold
        self.retryOnContextLimitError = retryOnContextLimitError
    }
}

public struct AgentContextCompactionConfiguration: Codable, Hashable, Sendable {
    public var isEnabled: Bool
    public var mode: AgentContextCompactionMode
    public var visibility: AgentContextCompactionVisibility
    public var strategy: AgentContextCompactionStrategy
    public var trigger: AgentContextCompactionTrigger

    public init(
        isEnabled: Bool = false,
        mode: AgentContextCompactionMode = .automatic,
        visibility: AgentContextCompactionVisibility = .hidden,
        strategy: AgentContextCompactionStrategy = .preferRemoteThenLocal,
        trigger: AgentContextCompactionTrigger = AgentContextCompactionTrigger()
    ) {
        self.isEnabled = isEnabled
        self.mode = mode
        self.visibility = visibility
        self.strategy = strategy
        self.trigger = trigger
    }
}

public enum AgentContextCompactionReason: String, Codable, Hashable, Sendable {
    case manual
    case automaticPreTurn
    case automaticRetry
    case modelChange
}

public struct AgentContextCompactionMarker: Codable, Hashable, Sendable {
    public let generation: Int
    public let reason: AgentContextCompactionReason
    public let effectiveMessageCountBefore: Int
    public let effectiveMessageCountAfter: Int
    public let debugSummaryPreview: String?

    public init(
        generation: Int,
        reason: AgentContextCompactionReason,
        effectiveMessageCountBefore: Int,
        effectiveMessageCountAfter: Int,
        debugSummaryPreview: String? = nil
    ) {
        self.generation = generation
        self.reason = reason
        self.effectiveMessageCountBefore = effectiveMessageCountBefore
        self.effectiveMessageCountAfter = effectiveMessageCountAfter
        self.debugSummaryPreview = debugSummaryPreview
    }
}

public struct AgentThreadContextState: Codable, Hashable, Sendable {
    public let threadID: String
    public let effectiveMessages: [AgentMessage]
    public let generation: Int
    public let lastCompactedAt: Date?
    public let lastCompactionReason: AgentContextCompactionReason?
    public let latestMarkerID: String?

    public init(
        threadID: String,
        effectiveMessages: [AgentMessage],
        generation: Int = 0,
        lastCompactedAt: Date? = nil,
        lastCompactionReason: AgentContextCompactionReason? = nil,
        latestMarkerID: String? = nil
    ) {
        self.threadID = threadID
        self.effectiveMessages = effectiveMessages
        self.generation = generation
        self.lastCompactedAt = lastCompactedAt
        self.lastCompactionReason = lastCompactionReason
        self.latestMarkerID = latestMarkerID
    }
}

public struct AgentCompactionResult: Codable, Hashable, Sendable {
    public let effectiveMessages: [AgentMessage]
    public let summaryPreview: String?

    public init(
        effectiveMessages: [AgentMessage],
        summaryPreview: String? = nil
    ) {
        self.effectiveMessages = effectiveMessages
        self.summaryPreview = summaryPreview
    }
}

public protocol AgentBackendContextCompacting: Sendable {
    func compactContext(
        thread: AgentThread,
        effectiveHistory: [AgentMessage],
        instructions: String,
        tools: [ToolDefinition],
        session: ChatGPTSession
    ) async throws -> AgentCompactionResult
}

public struct ThreadContextStateQuery: AgentQuerySpec {
    public typealias Result = [AgentThreadContextState]

    public var threadIDs: Set<String>?
    public var limit: Int?

    public init(
        threadIDs: Set<String>? = nil,
        limit: Int? = nil
    ) {
        self.threadIDs = threadIDs
        self.limit = limit
    }

    public func execute(in state: StoredRuntimeState) throws -> [AgentThreadContextState] {
        state.execute(self)
    }
}
