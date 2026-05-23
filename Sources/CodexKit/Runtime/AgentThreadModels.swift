import Foundation

public enum AgentRole: String, Codable, Hashable, Sendable {
    case user
    case assistant
    case tool
    case system
}

public enum AgentThreadStatus: String, Codable, Hashable, Sendable {
    case idle
    case streaming
    case waitingForApproval
    case waitingForToolResult
    case failed
}

public enum AgentTurnStatus: String, Codable, Hashable, Sendable {
    case running
    case completed
    case failed
}

public struct AgentThreadConfiguration: Codable, Hashable, Sendable {
    public var model: String
    public var reasoningEffort: ReasoningEffort

    public init(
        model: String,
        reasoningEffort: ReasoningEffort
    ) {
        self.model = model
        self.reasoningEffort = reasoningEffort
    }
}

public struct AgentUsage: Codable, Hashable, Sendable {
    public var inputTokens: Int
    public var cachedInputTokens: Int
    public var outputTokens: Int

    public init(inputTokens: Int = 0, cachedInputTokens: Int = 0, outputTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
    }
}

public struct AgentThread: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var title: String?
    public var configuration: AgentThreadConfiguration?
    public var personaStack: AgentPersonaStack?
    public var skillIDs: [String]
    public var memoryContext: AgentMemoryContext?
    public var createdAt: Date
    public var updatedAt: Date
    public var status: AgentThreadStatus

    public init(
        id: String,
        title: String? = nil,
        configuration: AgentThreadConfiguration? = nil,
        personaStack: AgentPersonaStack? = nil,
        skillIDs: [String] = [],
        memoryContext: AgentMemoryContext? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        status: AgentThreadStatus = .idle
    ) {
        self.id = id
        self.title = title
        self.configuration = configuration
        self.personaStack = personaStack
        self.skillIDs = skillIDs
        self.memoryContext = memoryContext
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.status = status
    }

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case configuration
        case personaStack
        case skillIDs
        case memoryContext
        case createdAt
        case updatedAt
        case status
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        configuration = try container.decodeIfPresent(AgentThreadConfiguration.self, forKey: .configuration)
        personaStack = try container.decodeIfPresent(AgentPersonaStack.self, forKey: .personaStack)
        skillIDs = try container.decodeIfPresent([String].self, forKey: .skillIDs) ?? []
        memoryContext = try container.decodeIfPresent(AgentMemoryContext.self, forKey: .memoryContext)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        status = try container.decodeIfPresent(AgentThreadStatus.self, forKey: .status) ?? .idle
    }
}

public struct AgentTurn: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var threadID: String
    public var status: AgentTurnStatus
    public var startedAt: Date

    public init(
        id: String,
        threadID: String,
        status: AgentTurnStatus = .running,
        startedAt: Date = Date()
    ) {
        self.id = id
        self.threadID = threadID
        self.status = status
        self.startedAt = startedAt
    }
}

public struct AgentMessage: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var threadID: String
    public var role: AgentRole
    public var text: String
    public var images: [AgentImageAttachment]
    public var structuredOutput: AgentStructuredOutputMetadata?
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        threadID: String,
        role: AgentRole,
        text: String,
        images: [AgentImageAttachment] = [],
        structuredOutput: AgentStructuredOutputMetadata? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.threadID = threadID
        self.role = role
        self.text = text
        self.images = images
        self.structuredOutput = structuredOutput
        self.createdAt = createdAt
    }

    public var displayText: String {
        if !text.isEmpty {
            return text
        }

        if images.count == 1 {
            return "Attached 1 image"
        }

        if !images.isEmpty {
            return "Attached \(images.count) images"
        }

        return ""
    }

    enum CodingKeys: String, CodingKey {
        case id
        case threadID
        case role
        case text
        case images
        case structuredOutput
        case createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        threadID = try container.decode(String.self, forKey: .threadID)
        role = try container.decode(AgentRole.self, forKey: .role)
        text = try container.decode(String.self, forKey: .text)
        images = try container.decodeIfPresent([AgentImageAttachment].self, forKey: .images) ?? []
        structuredOutput = try container.decodeIfPresent(
            AgentStructuredOutputMetadata.self,
            forKey: .structuredOutput
        )
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

public struct AgentTurnSummary: Codable, Hashable, Sendable {
    public var threadID: String
    public var turnID: String
    public var usage: AgentUsage?
    public var completedAt: Date

    public init(
        threadID: String,
        turnID: String,
        usage: AgentUsage? = nil,
        completedAt: Date = Date()
    ) {
        self.threadID = threadID
        self.turnID = turnID
        self.usage = usage
        self.completedAt = completedAt
    }
}
