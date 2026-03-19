import Foundation

public enum ApprovalDecision: String, Codable, Hashable, Sendable {
    case approved
    case denied
}

public struct ApprovalRequest: Identifiable, Hashable, Sendable {
    public let id: String
    public let threadID: String
    public let turnID: String
    public let toolInvocation: ToolInvocation
    public let title: String
    public let message: String

    public init(
        id: String = UUID().uuidString,
        threadID: String,
        turnID: String,
        toolInvocation: ToolInvocation,
        title: String,
        message: String
    ) {
        self.id = id
        self.threadID = threadID
        self.turnID = turnID
        self.toolInvocation = toolInvocation
        self.title = title
        self.message = message
    }
}

public struct ApprovalResolution: Hashable, Sendable {
    public let requestID: String
    public let threadID: String
    public let turnID: String
    public let decision: ApprovalDecision
    public let decidedAt: Date

    public init(
        requestID: String,
        threadID: String,
        turnID: String,
        decision: ApprovalDecision,
        decidedAt: Date = Date()
    ) {
        self.requestID = requestID
        self.threadID = threadID
        self.turnID = turnID
        self.decision = decision
        self.decidedAt = decidedAt
    }
}

public protocol ApprovalPresenting: Sendable {
    func requestApproval(_ request: ApprovalRequest) async throws -> ApprovalDecision
}
