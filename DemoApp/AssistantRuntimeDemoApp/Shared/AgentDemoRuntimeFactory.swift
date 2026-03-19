import CodexKit
import CodexKitUI
import Foundation
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif

enum DemoAuthenticationMethod: String, CaseIterable, Identifiable {
    case deviceCode
    case browserOAuth

    var id: String { rawValue }

    var buttonTitle: String {
        switch self {
        case .deviceCode:
            "Device Code"
        case .browserOAuth:
            "Browser OAuth (localhost)"
        }
    }
}

enum AgentDemoRuntimeFactory {
    private static let browserOAuthRedirectURI = URL(string: "http://localhost:1455/auth/callback")!

    #if canImport(AuthenticationServices)
    @MainActor
    @available(iOS 13.0, macOS 10.15, *)
    static func makeLive(
        redirectURI: URL,
        model: String = "gpt-5.4",
        enableWebSearch: Bool = false,
        stateURL: URL? = nil,
        keychainAccount: String = "live"
    ) -> AgentDemoViewModel {
        let approvalInbox = ApprovalInbox()
        let deviceCodePromptCoordinator = DeviceCodePromptCoordinator()
        let runtime = makeRuntime(
            authenticationMethod: .deviceCode,
            redirectURI: redirectURI,
            model: model,
            enableWebSearch: enableWebSearch,
            stateURL: stateURL,
            keychainAccount: keychainAccount,
            approvalInbox: approvalInbox,
            deviceCodePromptCoordinator: deviceCodePromptCoordinator
        )
        return AgentDemoViewModel(
            runtime: runtime,
            redirectURI: redirectURI,
            model: model,
            enableWebSearch: enableWebSearch,
            stateURL: stateURL,
            keychainAccount: keychainAccount,
            approvalInbox: approvalInbox,
            deviceCodePromptCoordinator: deviceCodePromptCoordinator
        )
    }
    #endif

    #if canImport(AuthenticationServices)
    @MainActor
    @available(iOS 13.0, macOS 10.15, *)
    static func makeRuntime(
        authenticationMethod: DemoAuthenticationMethod,
        redirectURI: URL,
        model: String = "gpt-5.4",
        enableWebSearch: Bool = false,
        stateURL: URL? = nil,
        keychainAccount: String = "live",
        approvalInbox: ApprovalInbox,
        deviceCodePromptCoordinator: DeviceCodePromptCoordinator
    ) -> AgentRuntime {
        let authProvider: any ChatGPTAuthProviding

        switch authenticationMethod {
        case .deviceCode:
            authProvider = try! ChatGPTAuthProvider(
                method: .deviceCode,
                deviceCodePresenter: deviceCodePromptCoordinator
            )

        case .browserOAuth:
            authProvider = try! ChatGPTAuthProvider(
                method: .oauth(redirectURI: browserOAuthRedirectURI)
            )
        }

        return try! AgentRuntime(configuration: .init(
            authProvider: authProvider,
            secureStore: KeychainSessionSecureStore(
                service: "AssistantRuntimeDemoApp.ChatGPTSession",
                account: keychainAccount
            ),
            backend: CodexResponsesBackend(
                configuration: CodexResponsesBackendConfiguration(
                    model: model,
                    enableWebSearch: enableWebSearch
                )
            ),
            approvalPresenter: approvalInbox,
            stateStore: FileRuntimeStateStore(url: stateURL ?? defaultStateURL())
        ))
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
