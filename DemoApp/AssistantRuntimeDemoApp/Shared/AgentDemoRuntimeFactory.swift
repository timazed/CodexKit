import CodexKit
import CodexKitUI
import Foundation
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif

enum AgentDemoRuntimeFactory {
    #if canImport(AuthenticationServices)
    @MainActor
    @available(iOS 13.0, macOS 10.15, *)
    static func makeLive(
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
                service: "AssistantRuntimeDemoApp.ChatGPTSession",
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
            .appendingPathComponent("AssistantRuntimeDemoApp", isDirectory: true)
            .appendingPathComponent("runtime-state.json")
    }
}
