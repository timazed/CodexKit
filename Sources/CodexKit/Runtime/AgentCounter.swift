import Foundation

package enum AgentCounter {
    package static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : result
    }

    package static func saturatingMultiply(_ lhs: Int, _ rhs: Int) -> Int {
        let (result, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        return overflow ? Int.max : result
    }

    package static func adding(
        _ amount: Int,
        to value: Int,
        field: String,
        threadID: String
    ) throws -> Int {
        guard value >= 0, amount >= 0 else {
            throw invalid(field: field, threadID: threadID)
        }
        let (result, overflow) = value.addingReportingOverflow(amount)
        guard !overflow else {
            throw invalid(field: field, threadID: threadID)
        }
        return result
    }

    package static func incrementing(
        _ value: Int,
        field: String,
        threadID: String
    ) throws -> Int {
        try adding(1, to: value, field: field, threadID: threadID)
    }

    private static func invalid(field: String, threadID: String) -> AgentRuntimeError {
        AgentRuntimeError(
            code: "invalid_runtime_counter",
            message: "Cannot increment \(field) for thread \(threadID): counter space exhausted."
        )
    }
}
