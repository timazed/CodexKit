import AssistantRuntimeKit
import Foundation
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif

public enum AssistantDemoRuntimeFactory {
    @MainActor
    public static func make() -> (runtime: AgentRuntime, viewModel: AssistantDemoViewModel) {
        makeMock()
    }

    @MainActor
    public static func makeMock() -> (runtime: AgentRuntime, viewModel: AssistantDemoViewModel) {
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

    #if canImport(AuthenticationServices)
    @MainActor
    @available(iOS 13.0, macOS 10.15, *)
    public static func makeLive(
        redirectURI: URL,
        model: String = "gpt-5",
        stateURL: URL? = nil,
        keychainAccount: String = "live"
    ) -> (runtime: AgentRuntime, viewModel: AssistantDemoViewModel) {
        let approvalInbox = ApprovalInbox()
        let bridge = HostBridge(
            authProvider: ChatGPTOAuthProvider(
                configuration: ChatGPTOAuthConfiguration(redirectURI: redirectURI),
                webAuthenticationProvider: SystemChatGPTWebAuthenticationProvider()
            ),
            secureStore: KeychainSessionSecureStore(
                service: "AssistantRuntimeDemo.ChatGPTSession",
                account: keychainAccount
            ),
            backend: CodexResponsesBackend(
                configuration: CodexResponsesBackendConfiguration(model: model)
            ),
            approvalPresenter: approvalInbox,
            stateStore: FileRuntimeStateStore(url: stateURL ?? defaultStateURL())
        )
        let runtime = AgentRuntime(hostBridge: bridge)
        let viewModel = AssistantDemoViewModel(runtime: runtime, approvalInbox: approvalInbox)
        return (runtime, viewModel)
    }
    #endif

    private static func defaultStateURL() -> URL {
        let baseDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())

        return baseDirectory
            .appendingPathComponent("AssistantRuntimeDemo", isDirectory: true)
            .appendingPathComponent("runtime-state.json")
    }
}
