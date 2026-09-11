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
            throw AgentRuntimeError(code: .invalidTurnLimits,
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
        switch knownCode {
        case .turnToolLimitExceeded: .toolCalls
        case .turnModelPassLimitExceeded: .modelPasses
        case .turnTimeLimitExceeded: .duration
        case .turnResponseByteLimitExceeded: .responseBytes
        case .turnResponseItemLimitExceeded: .responseItems
        default: nil
        }
    }

    static func executionLimitExceeded(_ limit: AgentExecutionLimit) -> AgentRuntimeError {
        switch limit {
        case .toolCalls:
            .init(code: .turnToolLimitExceeded, message: "The turn exceeded its configured tool-call limit.")
        case .modelPasses:
            .init(code: .turnModelPassLimitExceeded, message: "The turn exceeded its configured model-pass limit.")
        case .duration:
            .init(code: .turnTimeLimitExceeded, message: "The turn exceeded its configured duration.")
        case .responseBytes:
            .init(code: .turnResponseByteLimitExceeded, message: "The turn exceeded its configured response-byte limit.")
        case .responseItems:
            .init(code: .turnResponseItemLimitExceeded, message: "The turn exceeded the supported response-item limit.")
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
