import Foundation

public actor ApprovalCoordinator {
    private let presenter: any ApprovalPresenting

    public init(presenter: any ApprovalPresenting) {
        self.presenter = presenter
    }

    public func requestApproval(_ request: ApprovalRequest) async throws -> ApprovalDecision {
        try await presenter.requestApproval(request)
    }
}
