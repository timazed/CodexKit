import Foundation

/// An open wire value so future phases remain decodable.
public struct AgentMessagePhase: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let commentary = Self(rawValue: "commentary")
    public static let finalAnswer = Self(rawValue: "final_answer")

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Provider-supplied progress; reasoning summaries are separate from answer text.
public enum AgentProgress: Hashable, Sendable {
    case messageStarted(itemID: String, phase: AgentMessagePhase?)
    case messageCompleted(itemID: String, phase: AgentMessagePhase?)
    case reasoningSummaryDelta(itemID: String, summaryIndex: Int, delta: String)
    case webSearch(itemID: String, status: AgentWebSearchStatus, action: JSONValue?)

    public static func webSearch(itemID: String, status: String, action: JSONValue?) -> Self {
        .webSearch(itemID: itemID, status: AgentWebSearchStatus(rawValue: status), action: action)
    }
}

public struct AgentTurnProgress: Hashable, Sendable {
    public let threadID: String
    public let turnID: String
    public let content: AgentProgress

    public init(threadID: String, turnID: String, content: AgentProgress) {
        self.threadID = threadID
        self.turnID = turnID
        self.content = content
    }
}
