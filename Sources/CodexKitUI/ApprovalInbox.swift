import CodexKit
import Foundation
import Observation

@MainActor
@Observable
public final class ApprovalInbox: ApprovalPresenting, @unchecked Sendable {
    public private(set) var currentRequest: ApprovalRequest?

    private var continuation: CheckedContinuation<ApprovalDecision, Error>?

    public init() {}

    public func requestApproval(_ request: ApprovalRequest) async throws -> ApprovalDecision {
        currentRequest = request

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    public func approveCurrent() {
        continuation?.resume(returning: .approved)
        continuation = nil
        currentRequest = nil
    }

    public func denyCurrent() {
        continuation?.resume(returning: .denied)
        continuation = nil
        currentRequest = nil
    }
}
