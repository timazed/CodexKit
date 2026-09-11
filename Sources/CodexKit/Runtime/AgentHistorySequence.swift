import Foundation

package enum AgentHistorySequence {
    package static func next(after sequence: Int?, threadID: String) throws -> Int {
        let current = sequence ?? 0
        guard current >= 0 else {
            throw invalidSequence(threadID: threadID, detail: "negative sequence \(current)")
        }
        let (next, overflow) = current.addingReportingOverflow(1)
        guard !overflow else {
            throw invalidSequence(threadID: threadID, detail: "sequence space exhausted")
        }
        return next
    }

    package static func nextOrMaximum(after sequence: Int?) -> Int {
        let current = max(sequence ?? 0, 0)
        let (next, overflow) = current.addingReportingOverflow(1)
        return overflow ? Int.max : next
    }

    package static func validateAllocatable(
        _ sequence: Int,
        threadID: String
    ) throws {
        guard sequence > 0, sequence < Int.max else {
            throw invalidSequence(threadID: threadID, detail: "sequence space exhausted")
        }
    }

    private static func invalidSequence(
        threadID: String,
        detail: String
    ) -> AgentRuntimeError {
        AgentRuntimeError(
            code: .invalidHistorySequence,
            message: "Cannot allocate history for thread \(threadID): \(detail)."
        )
    }
}
