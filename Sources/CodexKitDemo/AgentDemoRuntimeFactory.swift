import CodexKit
import CodexKitUI
import Foundation
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif

public enum AgentDemoRuntimeFactory {
    @MainActor
    public static func make() -> (runtime: AgentRuntime, viewModel: AgentDemoViewModel) {
        makeMock()
    }

    @MainActor
    public static func makeMock() -> (runtime: AgentRuntime, viewModel: AgentDemoViewModel) {
        let approvalInbox = ApprovalInbox()
        let deviceCodePromptCoordinator = DeviceCodePromptCoordinator()
        let runtime = try! AgentRuntime(configuration: .init(
            authProvider: DemoChatGPTAuthProvider(),
            secureStore: KeychainSessionSecureStore(
                service: "CodexKitDemo.ChatGPTSession",
                account: "demo"
            ),
            backend: InMemoryAgentBackend(),
            approvalPresenter: approvalInbox,
            stateStore: InMemoryRuntimeStateStore()
        ))
        let viewModel = AgentDemoViewModel(
            runtime: runtime,
            approvalInbox: approvalInbox,
            deviceCodePromptCoordinator: deviceCodePromptCoordinator
        )
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
    ) -> (runtime: AgentRuntime, viewModel: AgentDemoViewModel) {
        let approvalInbox = ApprovalInbox()
        let deviceCodePromptCoordinator = DeviceCodePromptCoordinator()
        let runtime = try! AgentRuntime(configuration: .init(
            authProvider: ChatGPTDeviceCodeAuthProvider(
                configuration: ChatGPTOAuthConfiguration(redirectURI: redirectURI),
                presenter: deviceCodePromptCoordinator
            ),
            secureStore: KeychainSessionSecureStore(
                service: "CodexKitDemo.ChatGPTSession",
                account: keychainAccount
            ),
            backend: CodexResponsesBackend(
                configuration: CodexResponsesBackendConfiguration(model: model)
            ),
            approvalPresenter: approvalInbox,
            stateStore: FileRuntimeStateStore(url: stateURL ?? defaultStateURL())
        ))
        let viewModel = AgentDemoViewModel(
            runtime: runtime,
            approvalInbox: approvalInbox,
            deviceCodePromptCoordinator: deviceCodePromptCoordinator
        )
        return (runtime, viewModel)
    }
    #endif

    private static func defaultStateURL() -> URL {
        let baseDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())

        return baseDirectory
            .appendingPathComponent("CodexKitDemo", isDirectory: true)
            .appendingPathComponent("runtime-state.json")
    }
}
