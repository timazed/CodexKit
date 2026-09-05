import CodexKit
import Foundation
import Observation

@MainActor
@Observable
public final class ApprovalInbox: ApprovalPresenting {
    public private(set) var currentRequest: ApprovalRequest?
    private var requests: [ApprovalRequest] = []
    private var continuations: [String: CheckedContinuation<ApprovalDecision, Error>] = [:]

    public init() {}

    public func requestApproval(_ request: ApprovalRequest) async throws -> ApprovalDecision {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                requests.append(request)
                continuations[request.id] = continuation
                currentRequest = requests.first
            }
        } onCancel: {
            Task { @MainActor in self.cancel(request.id) }
        }
    }

    public func approveCurrent() { resolveCurrent(.approved) }
    public func denyCurrent() { resolveCurrent(.denied) }

    private func resolveCurrent(_ decision: ApprovalDecision) {
        guard let id = currentRequest?.id else { return }
        continuations.removeValue(forKey: id)?.resume(returning: decision)
        requests.removeAll { $0.id == id }
        currentRequest = requests.first
    }

    private func cancel(_ id: String) {
        continuations.removeValue(forKey: id)?.resume(throwing: CancellationError())
        requests.removeAll { $0.id == id }
        currentRequest = requests.first
    }
}
