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
    static let defaultModel = "gpt-5.4"
    static let defaultKeychainAccount = "AssistantRuntimeDemoApp"

    #if canImport(AuthenticationServices)
    @MainActor
    @available(iOS 13.0, macOS 10.15, *)
    static func makeLive(
        model: String = defaultModel,
        enableWebSearch: Bool = false,
        reasoningEffort: ReasoningEffort = .medium,
        stateURL: URL? = nil,
        keychainAccount: String = defaultKeychainAccount
    ) -> AgentDemoViewModel {
        let approvalInbox = ApprovalInbox()
        let deviceCodePromptCoordinator = DeviceCodePromptCoordinator()
        let runtime = makeRuntime(
            authenticationMethod: .deviceCode,
            model: model,
            enableWebSearch: enableWebSearch,
            reasoningEffort: reasoningEffort,
            stateURL: stateURL,
            keychainAccount: keychainAccount,
            approvalInbox: approvalInbox,
            deviceCodePromptCoordinator: deviceCodePromptCoordinator
        )
        return AgentDemoViewModel(
            runtime: runtime,
            model: model,
            enableWebSearch: enableWebSearch,
            reasoningEffort: reasoningEffort,
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
        model: String = defaultModel,
        enableWebSearch: Bool = false,
        reasoningEffort: ReasoningEffort = .medium,
        stateURL: URL? = nil,
        keychainAccount: String = defaultKeychainAccount,
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
                method: .oauth
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
                    reasoningEffort: reasoningEffort,
                    enableWebSearch: enableWebSearch
                )
            ),
            approvalPresenter: approvalInbox,
            stateStore: FileRuntimeStateStore(url: stateURL ?? defaultStateURL()),
            memory: .init(
                store: try! SQLiteMemoryStore(url: defaultMemoryURL()),
                automaticCapturePolicy: .init(
                    source: .lastTurn,
                    options: .init(
                        defaults: .init(
                            namespace: DemoMemoryExamples.namespace,
                            kind: "preference",
                            tags: ["demo", "auto-capture"]
                        ),
                        maxMemories: 2
                    )
                )
            )
        ))
    }
    #endif

    static func makeRestorableRuntimeForSystemIntegration(
        model: String = defaultModel,
        enableWebSearch: Bool = true,
        reasoningEffort: ReasoningEffort = .medium,
        keychainAccount: String = defaultKeychainAccount
    ) -> AgentRuntime {
        let authProvider = try! ChatGPTAuthProvider(method: .oauth)

        return try! AgentRuntime(configuration: .init(
            authProvider: authProvider,
            secureStore: KeychainSessionSecureStore(
                service: "AssistantRuntimeDemoApp.ChatGPTSession",
                account: keychainAccount
            ),
            backend: CodexResponsesBackend(
                configuration: CodexResponsesBackendConfiguration(
                    model: model,
                    reasoningEffort: reasoningEffort,
                    enableWebSearch: enableWebSearch
                )
            ),
            approvalPresenter: NonInteractiveApprovalPresenter(),
            stateStore: FileRuntimeStateStore(url: defaultStateURL()),
            memory: .init(
                store: try! SQLiteMemoryStore(url: defaultMemoryURL()),
                automaticCapturePolicy: .init(
                    source: .lastTurn,
                    options: .init(
                        defaults: .init(
                            namespace: DemoMemoryExamples.namespace,
                            kind: "preference",
                            tags: ["demo", "auto-capture"]
                        ),
                        maxMemories: 2
                    )
                )
            )
        ))
    }

    static func defaultStateURL() -> URL {
        let baseDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())

        return baseDirectory
            .appendingPathComponent("AssistantRuntimeDemoApp", isDirectory: true)
            .appendingPathComponent("runtime-state.json")
    }

    static func defaultMemoryURL() -> URL {
        let baseDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())

        return baseDirectory
            .appendingPathComponent("AssistantRuntimeDemoApp", isDirectory: true)
            .appendingPathComponent("memory.sqlite")
    }
}

private struct NonInteractiveApprovalPresenter: ApprovalPresenting {
    func requestApproval(_ request: ApprovalRequest) async throws -> ApprovalDecision {
        .denied
    }
}
