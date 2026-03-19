import Foundation

actor ApprovalCoordinator {
    private let presenter: any ApprovalPresenting

    init(presenter: any ApprovalPresenting) {
        self.presenter = presenter
    }

    func requestApproval(_ request: ApprovalRequest) async throws -> ApprovalDecision {
        try await presenter.requestApproval(request)
    }
}
