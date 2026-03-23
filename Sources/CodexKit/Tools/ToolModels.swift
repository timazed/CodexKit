import Foundation

public enum ToolApprovalPolicy: String, Codable, Hashable, Sendable {
    case automatic
    case requiresApproval
}

public struct ToolDefinition: Identifiable, Hashable, Sendable {
    private static let validNamePattern = "^[a-zA-Z0-9_-]+$"

    public var id: String { name }
    public let name: String
    public let description: String
    public let inputSchema: JSONValue
    public let approvalPolicy: ToolApprovalPolicy
    public let approvalMessage: String?

    public init(
        name: String,
        description: String,
        inputSchema: JSONValue,
        approvalPolicy: ToolApprovalPolicy = .automatic,
        approvalMessage: String? = nil
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.approvalPolicy = approvalPolicy
        self.approvalMessage = approvalMessage
    }

    public static func isValidName(_ name: String) -> Bool {
        name.range(of: validNamePattern, options: .regularExpression) != nil
    }
}

public struct ToolInvocation: Identifiable, Hashable, Sendable {
    public let id: String
    public let threadID: String
    public let turnID: String
    public let toolName: String
    public let arguments: JSONValue

    public init(
        id: String,
        threadID: String,
        turnID: String,
        toolName: String,
        arguments: JSONValue
    ) {
        self.id = id
        self.threadID = threadID
        self.turnID = turnID
        self.toolName = toolName
        self.arguments = arguments
    }
}

extension ToolInvocation: Codable {}

public enum ToolResultContent: Hashable, Sendable {
    case text(String)
    case image(URL)

    public var textValue: String? {
        guard case let .text(value) = self else {
            return nil
        }
        return value
    }
}

extension ToolResultContent: Codable {}

public struct ToolSessionDescriptor: Codable, Hashable, Sendable {
    public let sessionID: String
    public let status: String
    public let metadata: JSONValue?
    public let resumable: Bool
    public let isTerminal: Bool

    public init(
        sessionID: String,
        status: String,
        metadata: JSONValue? = nil,
        resumable: Bool = false,
        isTerminal: Bool = true
    ) {
        self.sessionID = sessionID
        self.status = status
        self.metadata = metadata
        self.resumable = resumable
        self.isTerminal = isTerminal
    }
}

public struct ToolResultEnvelope: Hashable, Sendable {
    public let invocationID: String
    public let toolName: String
    public let success: Bool
    public let content: [ToolResultContent]
    public let errorMessage: String?
    public let session: ToolSessionDescriptor?

    public init(
        invocationID: String,
        toolName: String,
        success: Bool,
        content: [ToolResultContent] = [],
        errorMessage: String? = nil,
        session: ToolSessionDescriptor? = nil
    ) {
        self.invocationID = invocationID
        self.toolName = toolName
        self.success = success
        self.content = content
        self.errorMessage = errorMessage
        self.session = session
    }

    public var primaryText: String? {
        content.compactMap(\.textValue).first
    }

    public static func success(
        invocation: ToolInvocation,
        text: String,
        session: ToolSessionDescriptor? = nil
    ) -> ToolResultEnvelope {
        ToolResultEnvelope(
            invocationID: invocation.id,
            toolName: invocation.toolName,
            success: true,
            content: [.text(text)],
            session: session
        )
    }

    public static func failure(
        invocation: ToolInvocation,
        message: String,
        session: ToolSessionDescriptor? = nil
    ) -> ToolResultEnvelope {
        ToolResultEnvelope(
            invocationID: invocation.id,
            toolName: invocation.toolName,
            success: false,
            content: [.text(message)],
            errorMessage: message,
            session: session
        )
    }

    public static func denied(
        invocation: ToolInvocation,
        session: ToolSessionDescriptor? = nil
    ) -> ToolResultEnvelope {
        failure(
            invocation: invocation,
            message: "Tool execution was denied by the user.",
            session: session
        )
    }
}

extension ToolResultEnvelope: Codable {}

public struct ToolExecutionContext: Sendable {
    public let threadID: String
    public let turnID: String
    public let session: ChatGPTSession?

    public init(threadID: String, turnID: String, session: ChatGPTSession?) {
        self.threadID = threadID
        self.turnID = turnID
        self.session = session
    }
}

public protocol ToolExecuting: Sendable {
    func execute(
        invocation: ToolInvocation,
        context: ToolExecutionContext
    ) async throws -> ToolResultEnvelope
}

public struct AnyToolExecutor: ToolExecuting, Sendable {
    private let closure: @Sendable (ToolInvocation, ToolExecutionContext) async throws -> ToolResultEnvelope

    public init(
        _ closure: @escaping @Sendable (ToolInvocation, ToolExecutionContext) async throws -> ToolResultEnvelope
    ) {
        self.closure = closure
    }

    public func execute(
        invocation: ToolInvocation,
        context: ToolExecutionContext
    ) async throws -> ToolResultEnvelope {
        try await closure(invocation, context)
    }
}
