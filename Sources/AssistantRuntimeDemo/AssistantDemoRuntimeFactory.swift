import AssistantRuntimeKit
import Foundation

public enum AssistantDemoRuntimeFactory {
    @MainActor
    public static func make() -> (runtime: AgentRuntime, viewModel: AssistantDemoViewModel) {
        let approvalInbox = ApprovalInbox()
        let bridge = HostBridge(
            authProvider: DemoChatGPTAuthProvider(),
            secureStore: KeychainSessionSecureStore(
                service: "AssistantRuntimeDemo.ChatGPTSession",
                account: "demo"
            ),
            backend: InMemoryAssistantBackend(),
            approvalPresenter: approvalInbox,
            stateStore: InMemoryRuntimeStateStore()
        )
        let runtime = AgentRuntime(hostBridge: bridge)
        let viewModel = AssistantDemoViewModel(runtime: runtime, approvalInbox: approvalInbox)
        return (runtime, viewModel)
    }
}
