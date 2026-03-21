import Foundation

public struct AgentSkillExecutionPolicy: Codable, Hashable, Sendable {
    public var allowedToolNames: [String]? = nil
    public var requiredToolNames: [String] = []
    public var toolSequence: [String]? = nil
    public var maxToolCalls: Int? = nil

    public init(
        allowedToolNames: [String]? = nil,
        requiredToolNames: [String] = [],
        toolSequence: [String]? = nil,
        maxToolCalls: Int? = nil
    ) {
        self.allowedToolNames = allowedToolNames
        self.requiredToolNames = requiredToolNames
        self.toolSequence = toolSequence
        self.maxToolCalls = maxToolCalls
    }

    enum CodingKeys: String, CodingKey {
        case allowedToolNames
        case requiredToolNames
        case toolSequence
        case maxToolCalls
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        allowedToolNames = try container.decodeIfPresent([String].self, forKey: .allowedToolNames)
        requiredToolNames = try container.decodeIfPresent([String].self, forKey: .requiredToolNames) ?? []
        toolSequence = try container.decodeIfPresent([String].self, forKey: .toolSequence)
        maxToolCalls = try container.decodeIfPresent(Int.self, forKey: .maxToolCalls)
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
