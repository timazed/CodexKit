import Foundation

public struct AgentRuntimeError: Error, LocalizedError, Equatable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? {
        message
    }

    public static func signedOut() -> AgentRuntimeError {
        AgentRuntimeError(code: "signed_out", message: "No ChatGPT session is available.")
    }

    public static func threadNotFound(_ threadID: String) -> AgentRuntimeError {
        AgentRuntimeError(
            code: "thread_not_found",
            message: "The assistant thread \(threadID) could not be found."
        )
    }

    public static func unauthorized(_ message: String = "The ChatGPT session is no longer authorized.") -> AgentRuntimeError {
        AgentRuntimeError(code: "unauthorized", message: message)
    }

    public static func invalidMessageContent() -> AgentRuntimeError {
        AgentRuntimeError(
            code: "invalid_message_content",
            message: "A user message must include text or at least one image attachment."
        )
    }

    public static func invalidSkillID(_ skillID: String) -> AgentRuntimeError {
        AgentRuntimeError(
            code: "invalid_skill_id",
            message: "The skill ID \(skillID) is invalid. Skill IDs must match ^[a-zA-Z0-9_-]+$."
        )
    }

    public static func duplicateSkill(_ skillID: String) -> AgentRuntimeError {
        AgentRuntimeError(
            code: "duplicate_skill",
            message: "A skill with ID \(skillID) is already registered."
        )
    }

    public static func skillsNotFound(_ skillIDs: [String]) -> AgentRuntimeError {
        let joined = skillIDs.sorted().joined(separator: ", ")
        return AgentRuntimeError(
            code: "skills_not_found",
            message: "The following skills are not registered: \(joined)."
        )
    }

    public static func invalidSkillToolName(
        skillID: String,
        toolName: String
    ) -> AgentRuntimeError {
        AgentRuntimeError(
            code: "invalid_skill_tool_name",
            message: "Skill \(skillID) references invalid tool name \(toolName). Tool names must match ^[a-zA-Z0-9_-]+$."
        )
    }

    public static func invalidSkillMaxToolCalls(skillID: String) -> AgentRuntimeError {
        AgentRuntimeError(
            code: "invalid_skill_max_tool_calls",
            message: "Skill \(skillID) has invalid maxToolCalls. It must be 0 or greater."
        )
    }

    public static func skillToolNotAllowed(_ toolName: String) -> AgentRuntimeError {
        AgentRuntimeError(
            code: "skill_tool_not_allowed",
            message: "Tool \(toolName) is not allowed by the active skill policy."
        )
    }

    public static func skillToolSequenceViolation(
        expected: String,
        actual: String
    ) -> AgentRuntimeError {
        AgentRuntimeError(
            code: "skill_tool_sequence_violation",
            message: "Tool \(actual) was requested out of sequence. Expected \(expected)."
        )
    }

    public static func skillToolCallLimitExceeded(_ maxCalls: Int) -> AgentRuntimeError {
        AgentRuntimeError(
            code: "skill_tool_call_limit_exceeded",
            message: "The active skill policy allows at most \(maxCalls) tool call(s) per turn."
        )
    }

    public static func skillRequiredToolsMissing(_ toolNames: [String]) -> AgentRuntimeError {
        AgentRuntimeError(
            code: "skill_required_tools_missing",
            message: "The active skill policy requires tool calls that did not occur: \(toolNames.sorted().joined(separator: ", "))."
        )
    }
}

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

public struct AgentImageAttachment: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let mimeType: String
    public let data: Data

    public init(
        id: String = UUID().uuidString,
        mimeType: String,
        data: Data
    ) {
        self.id = id
        self.mimeType = mimeType
        self.data = data
    }

    public static func png(
        _ data: Data,
        id: String = UUID().uuidString
    ) -> AgentImageAttachment {
        AgentImageAttachment(id: id, mimeType: "image/png", data: data)
    }

    public static func jpeg(
        _ data: Data,
        id: String = UUID().uuidString
    ) -> AgentImageAttachment {
        AgentImageAttachment(id: id, mimeType: "image/jpeg", data: data)
    }

    public var dataURLString: String {
        "data:\(mimeType);base64,\(data.base64EncodedString())"
    }

    public init?(
        dataURLString: String,
        id: String = UUID().uuidString
    ) {
        let prefix = "data:"
        guard dataURLString.hasPrefix(prefix),
              let separatorIndex = dataURLString.range(of: ";base64,")
        else {
            return nil
        }

        let mimeTypeStart = dataURLString.index(dataURLString.startIndex, offsetBy: prefix.count)
        let mimeType = String(dataURLString[mimeTypeStart ..< separatorIndex.lowerBound])
        let base64Start = separatorIndex.upperBound
        let base64 = String(dataURLString[base64Start...])

        self.init(id: id, mimeType: mimeType, data: Data(base64Encoded: base64) ?? Data())
        if data.isEmpty {
            return nil
        }
    }

    public init?(
        base64String: String,
        mimeType: String = "image/png",
        id: String = UUID().uuidString
    ) {
        guard let data = Data(base64Encoded: base64String), !data.isEmpty else {
            return nil
        }

        self.init(id: id, mimeType: mimeType, data: data)
    }
}

public struct UserMessageRequest: Codable, Hashable, Sendable {
    public var text: String
    public var images: [AgentImageAttachment]
    public var personaOverride: AgentPersonaStack?
    public var skillOverrideIDs: [String]?
    public var memorySelection: MemorySelection?

    public init(
        text: String,
        images: [AgentImageAttachment] = [],
        personaOverride: AgentPersonaStack? = nil,
        skillOverrideIDs: [String]? = nil,
        memorySelection: MemorySelection? = nil
    ) {
        self.text = text
        self.images = images
        self.personaOverride = personaOverride
        self.skillOverrideIDs = skillOverrideIDs
        self.memorySelection = memorySelection
    }

    public var hasContent: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty
    }

    enum CodingKeys: String, CodingKey {
        case text
        case images
        case personaOverride
        case skillOverrideIDs
        case memorySelection
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        images = try container.decodeIfPresent([AgentImageAttachment].self, forKey: .images) ?? []
        personaOverride = try container.decodeIfPresent(AgentPersonaStack.self, forKey: .personaOverride)
        skillOverrideIDs = try container.decodeIfPresent([String].self, forKey: .skillOverrideIDs)
        memorySelection = try container.decodeIfPresent(MemorySelection.self, forKey: .memorySelection)
    }
}

public struct AgentThread: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var title: String?
    public var personaStack: AgentPersonaStack?
    public var skillIDs: [String]
    public var memoryContext: AgentMemoryContext?
    public var createdAt: Date
    public var updatedAt: Date
    public var status: AgentThreadStatus

    public init(
        id: String,
        title: String? = nil,
        personaStack: AgentPersonaStack? = nil,
        skillIDs: [String] = [],
        memoryContext: AgentMemoryContext? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        status: AgentThreadStatus = .idle
    ) {
        self.id = id
        self.title = title
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
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        threadID: String,
        role: AgentRole,
        text: String,
        images: [AgentImageAttachment] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.threadID = threadID
        self.role = role
        self.text = text
        self.images = images
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
        case createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        threadID = try container.decode(String.self, forKey: .threadID)
        role = try container.decode(AgentRole.self, forKey: .role)
        text = try container.decode(String.self, forKey: .text)
        images = try container.decodeIfPresent([AgentImageAttachment].self, forKey: .images) ?? []
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

public enum AgentEvent: Sendable {
    case threadStarted(AgentThread)
    case threadStatusChanged(threadID: String, status: AgentThreadStatus)
    case turnStarted(AgentTurn)
    case assistantMessageDelta(threadID: String, turnID: String, delta: String)
    case messageCommitted(AgentMessage)
    case approvalRequested(ApprovalRequest)
    case approvalResolved(ApprovalResolution)
    case toolCallStarted(ToolInvocation)
    case toolCallFinished(ToolResultEnvelope)
    case turnCompleted(AgentTurnSummary)
    case turnFailed(AgentRuntimeError)
}
