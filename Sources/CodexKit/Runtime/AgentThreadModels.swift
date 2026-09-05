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
    case interrupted
    case completed
    case failed
}

public struct AgentThreadConfiguration: Codable, Hashable, Sendable {
    public var model: String
    public var reasoningEffort: ReasoningEffort

    public var codexModel: CodexModel {
        get { CodexModel(rawValue: model) }
        set { model = newValue.rawValue }
    }

    public init(
        model: String,
        reasoningEffort: ReasoningEffort
    ) {
        self.model = model
        self.reasoningEffort = reasoningEffort
    }

    public init(
        model: CodexModel,
        reasoningEffort: ReasoningEffort? = nil
    ) {
        self.init(
            model: model.rawValue,
            reasoningEffort: reasoningEffort ?? model.info?.defaultReasoningEffort ?? .medium
        )
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
    public var phase: AgentMessagePhase?
    public var structuredOutput: AgentStructuredOutputMetadata?
    /// A complete historical tool call/result relationship represented as one
    /// atomic context item. Backends that understand tool history can replay
    /// the original provider call ID and arguments without exposing a partial
    /// call when a bounded context window is hydrated.
    public var toolInteraction: AgentToolInteraction?
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        threadID: String,
        role: AgentRole,
        text: String,
        images: [AgentImageAttachment] = [],
        phase: AgentMessagePhase? = nil,
        structuredOutput: AgentStructuredOutputMetadata? = nil,
        toolInteraction: AgentToolInteraction? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.threadID = threadID
        self.role = role
        self.text = text
        self.images = images
        self.phase = phase
        self.structuredOutput = structuredOutput
        self.toolInteraction = toolInteraction
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
        case phase
        case structuredOutput
        case toolInteraction
        case createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        threadID = try container.decode(String.self, forKey: .threadID)
        role = try container.decode(AgentRole.self, forKey: .role)
        text = try container.decode(String.self, forKey: .text)
        images = try container.decodeIfPresent([AgentImageAttachment].self, forKey: .images) ?? []
        phase = try container.decodeIfPresent(AgentMessagePhase.self, forKey: .phase)
        structuredOutput = try container.decodeIfPresent(
            AgentStructuredOutputMetadata.self,
            forKey: .structuredOutput
        )
        toolInteraction = try container.decodeIfPresent(
            AgentToolInteraction.self,
            forKey: .toolInteraction
        )
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

/// The durable, model-facing representation of a completed tool interaction.
public struct AgentToolInteraction: Codable, Hashable, Sendable {
    public let invocation: ToolInvocation
    public let result: ToolResultEnvelope

    public init(
        invocation: ToolInvocation,
        result: ToolResultEnvelope
    ) {
        self.invocation = invocation
        self.result = result
    }
}

extension AgentMessage {
    var estimatedContextCharacterCount: Int {
        var characters = AgentCounter.saturatingAdd(
            text.count,
            AgentCounter.saturatingMultiply(images.count, 512)
        )
        guard let toolInteraction else {
            return characters
        }

        characters = AgentCounter.saturatingAdd(
            characters,
            toolInteraction.invocation.toolName.count
        )
        characters = AgentCounter.saturatingAdd(
            characters,
            toolInteraction.invocation.arguments.prettyJSONString.count
        )
        characters = AgentCounter.saturatingAdd(
            characters,
            toolInteraction.result.errorMessage?.count ?? 0
        )
        for content in toolInteraction.result.content {
            switch content {
            case let .text(text):
                characters = AgentCounter.saturatingAdd(characters, text.count)
            case let .image(url):
                characters = AgentCounter.saturatingAdd(
                    characters,
                    url.absoluteString.count
                )
            }
        }
        return characters
    }

    var modelContextItemCount: Int {
        toolInteraction == nil ? 1 : 2
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
