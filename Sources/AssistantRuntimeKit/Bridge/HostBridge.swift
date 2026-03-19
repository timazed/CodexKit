import Foundation

public struct HostBridge: Sendable {
    public let authProvider: any ChatGPTAuthProviding
    public let secureStore: any SessionSecureStoring
    public let backend: any AssistantBackend
    public let approvalPresenter: any ApprovalPresenting
    public let stateStore: any RuntimeStateStoring

    public init(
        authProvider: any ChatGPTAuthProviding,
        secureStore: any SessionSecureStoring,
        backend: any AssistantBackend,
        approvalPresenter: any ApprovalPresenting,
        stateStore: any RuntimeStateStoring
    ) {
        self.authProvider = authProvider
        self.secureStore = secureStore
        self.backend = backend
        self.approvalPresenter = approvalPresenter
        self.stateStore = stateStore
    }
}
