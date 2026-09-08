import Foundation

/// Applies to plain, structured, and ephemeral runtime turns. The duration
/// includes session resolution, approvals, tools, and waiting for event consumers.
public struct AgentTurnLimits: Hashable, Sendable {
    public let maximumToolCalls: Int?
    public let maximumDuration: TimeInterval?

    public init(maximumToolCalls: Int? = 128, maximumDuration: TimeInterval? = 300) {
        self.maximumToolCalls = maximumToolCalls
        self.maximumDuration = maximumDuration
    }

    public static let unlimited = AgentTurnLimits(maximumToolCalls: nil, maximumDuration: nil)

    func validate() throws {
        guard maximumToolCalls.map({ $0 >= 0 }) ?? true,
              maximumDuration.map({ $0.isFinite && $0 > 0 && $0 <= 31_536_000 }) ?? true else {
            throw AgentRuntimeError(code: "invalid_turn_limits",
                message: "Tool limits must be nonnegative; duration must be positive and at most one year, or nil for unlimited.")
        }
    }
}

public enum AgentExecutionLimit: String, Sendable {
    case toolCalls
    case modelPasses
    case duration
    case responseBytes
    case responseItems
}

public extension AgentRuntimeError {
    var executionLimit: AgentExecutionLimit? {
        switch code {
        case "turn_tool_limit_exceeded": .toolCalls
        case "turn_model_pass_limit_exceeded": .modelPasses
        case "turn_time_limit_exceeded": .duration
        case "turn_response_byte_limit_exceeded": .responseBytes
        case "turn_response_item_limit_exceeded": .responseItems
        default: nil
        }
    }

    static func executionLimitExceeded(_ limit: AgentExecutionLimit) -> AgentRuntimeError {
        switch limit {
        case .toolCalls:
            .init(code: "turn_tool_limit_exceeded", message: "The turn exceeded its configured tool-call limit.")
        case .modelPasses:
            .init(code: "turn_model_pass_limit_exceeded", message: "The turn exceeded its configured model-pass limit.")
        case .duration:
            .init(code: "turn_time_limit_exceeded", message: "The turn exceeded its configured duration.")
        case .responseBytes:
            .init(code: "turn_response_byte_limit_exceeded", message: "The turn exceeded its configured response-byte limit.")
        case .responseItems:
            .init(code: "turn_response_item_limit_exceeded", message: "The turn exceeded the supported response-item limit.")
        }
    }
}

final class AgentTurnBudget: @unchecked Sendable {
    private let lock = NSLock()
    private let limits: AgentTurnLimits
    let executionID: UUID?
    private var calls = 0
    private var finished = false
    private var failure: AgentRuntimeError?

    init(limits: AgentTurnLimits, executionID: UUID? = nil) {
        self.limits = limits
        self.executionID = executionID
    }

    var error: AgentRuntimeError? { lock.withLock { failure } }

    func claimToolCalls(_ count: Int) throws {
        try lock.withLock {
            if let failure { throw failure }
            if let maximum = limits.maximumToolCalls {
                guard count <= maximum - calls else {
                    let error = AgentRuntimeError.executionLimitExceeded(.toolCalls)
                    failure = error
                    throw error
                }
                calls += count
            }
        }
    }

    func expire() -> Bool {
        lock.withLock {
            guard !finished, failure == nil else { return false }
            failure = .executionLimitExceeded(.duration)
            return true
        }
    }

    func finish() { lock.withLock { finished = true } }

    /// Resolves the deadline/completion race before accepting a valid summary.
    func acceptCompletion() throws {
        try lock.withLock {
            if let failure { throw failure }
            finished = true
        }
    }
}
