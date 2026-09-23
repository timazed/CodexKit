import Foundation

/// All host tool calls requested by one model response, in provider order.
/// Backends emit exactly one round per tool-bearing response, regardless of
/// whether the host executes its calls serially or concurrently.
public struct AgentToolRound: Hashable, Sendable, Identifiable {
    public let id: String
    public let calls: [ToolInvocation]

    public init(id: String = UUID().uuidString, calls: [ToolInvocation]) {
        self.id = id
        self.calls = calls
    }
}
