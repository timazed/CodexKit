import Foundation

/// Selects a message and its linked structured output, or a tool call/result
/// pair, without loading unrelated history. Combine with `kinds` to select one side.
public enum AgentHistoryRelationship: Hashable, Sendable {
    case message(id: String)
    case toolInvocation(id: String)

    package enum StorageKind: String { case message, tool }

    package var storageKey: String {
        switch self {
        case let .message(id): AgentHistoryItem.relationshipKey(kind: .message, id: id)
        case let .toolInvocation(id): AgentHistoryItem.relationshipKey(kind: .tool, id: id)
        }
    }
}
