import Foundation

public struct AgentSkillExecutionPolicy: Codable, Hashable, Sendable {
    /// `nil` leaves tools unrestricted; an empty array disallows every tool.
    public var allowedToolNames: [String]? = nil
    public var requiredToolNames: [String] = []
    public var toolSequence: [String]? = nil
    public var maxToolCalls: Int? = nil
    public var webSearch: AgentWebSearchPolicy? = nil
    /// Number of model responses requesting host tools, including rejected rounds.
    public var maxToolRounds: Int? = nil
    public var maxToolCallsByName: [String: Int]? = nil
    /// Narrows the runtime's per-round concurrency ceiling. Must be at least one.
    public var maximumParallelToolCalls: Int? = nil

    public init(
        allowedToolNames: [String]? = nil,
        requiredToolNames: [String] = [],
        toolSequence: [String]? = nil,
        maxToolCalls: Int? = nil,
        maxToolRounds: Int? = nil,
        maxToolCallsByName: [String: Int]? = nil,
        maximumParallelToolCalls: Int? = nil,
        webSearch: AgentWebSearchPolicy? = nil
    ) {
        self.allowedToolNames = allowedToolNames
        self.requiredToolNames = requiredToolNames
        self.toolSequence = toolSequence
        self.maxToolCalls = maxToolCalls
        self.maxToolRounds = maxToolRounds
        self.maxToolCallsByName = maxToolCallsByName
        self.maximumParallelToolCalls = maximumParallelToolCalls
        self.webSearch = webSearch
    }

    enum CodingKeys: String, CodingKey {
        case allowedToolNames
        case requiredToolNames
        case toolSequence
        case maxToolCalls
        case maxToolRounds, maxToolCallsByName, maximumParallelToolCalls, webSearch
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        allowedToolNames = try container.decodeIfPresent([String].self, forKey: .allowedToolNames)
        requiredToolNames = try container.decodeIfPresent([String].self, forKey: .requiredToolNames) ?? []
        toolSequence = try container.decodeIfPresent([String].self, forKey: .toolSequence)
        maxToolCalls = try container.decodeIfPresent(Int.self, forKey: .maxToolCalls)
        webSearch = try container.decodeIfPresent(AgentWebSearchPolicy.self, forKey: .webSearch)
        maxToolRounds = try container.decodeIfPresent(Int.self, forKey: .maxToolRounds)
        maxToolCallsByName = try container.decodeIfPresent([String: Int].self, forKey: .maxToolCallsByName)
        maximumParallelToolCalls = try container.decodeIfPresent(Int.self, forKey: .maximumParallelToolCalls)
    }

    var hasValidLimits: Bool {
        (maxToolCalls.map { $0 >= 0 } ?? true) &&
        (maxToolRounds.map { $0 >= 0 } ?? true) &&
        (maxToolCallsByName?.values.allSatisfy { $0 >= 0 } ?? true) &&
        (maximumParallelToolCalls.map { $0 >= 1 } ?? true)
    }

    var policyToolNames: [String] {
        (allowedToolNames ?? []) + requiredToolNames + (toolSequence ?? []) +
        (maxToolCallsByName.map { Array($0.keys) } ?? [])
    }
}

public struct AgentSkill: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public var name: String
    public var instructions: String
    public var executionPolicy: AgentSkillExecutionPolicy?

    public init(
        id: String,
        name: String,
        instructions: String,
        executionPolicy: AgentSkillExecutionPolicy? = nil
    ) {
        self.id = id
        self.name = name
        self.instructions = instructions
        self.executionPolicy = executionPolicy
    }

    public static func isValidID(_ id: String) -> Bool {
        let pattern = "^[a-zA-Z0-9_-]+$"
        return id.range(of: pattern, options: .regularExpression) != nil
    }
}
