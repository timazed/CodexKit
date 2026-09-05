import CodexKit
import CodexKitRealm
import CodexKitSQLite
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

enum DemoPersistenceAdapter: String, CaseIterable, Identifiable, Sendable {
    case sqlite
    case realm

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sqlite:
            "SQLite"
        case .realm:
            "Realm"
        }
    }

    var runtimeFilename: String {
        switch self {
        case .sqlite:
            "runtime-state.sqlite"
        case .realm:
            "runtime-state.realm"
        }
    }

    var memoryFilename: String {
        switch self {
        case .sqlite:
            "memory.sqlite"
        case .realm:
            "memory.realm"
        }
    }
}

enum AgentDemoRuntimeFactory {
    static let defaultModel = CodexModel.gpt56Sol.rawValue
    static let defaultKeychainAccount = "AssistantRuntimeDemoApp"
    private static let persistenceAdapterDefaultsKey = "AssistantRuntimeDemoApp.persistenceAdapter"

    #if canImport(AuthenticationServices)
    @MainActor
    @available(iOS 13.0, macOS 10.15, *)
    static func makeLive(
        model: String = defaultModel,
        enableWebSearch: Bool = false,
        enableImageGeneration: Bool = false,
        reasoningEffort: ReasoningEffort = .low,
        persistenceAdapter: DemoPersistenceAdapter = initialPersistenceAdapter(),
        keychainAccount: String = defaultKeychainAccount
    ) throws -> AgentDemoViewModel {
        let approvalInbox = ApprovalInbox()
        let deviceCodePromptCoordinator = DeviceCodePromptCoordinator()
        let runtime = try makeRuntime(
            authenticationMethod: .deviceCode,
            model: model,
            enableWebSearch: enableWebSearch,
            enableImageGeneration: enableImageGeneration,
            reasoningEffort: reasoningEffort,
            persistenceAdapter: persistenceAdapter,
            keychainAccount: keychainAccount,
            approvalInbox: approvalInbox,
            deviceCodePromptCoordinator: deviceCodePromptCoordinator
        )
        return AgentDemoViewModel(
            runtime: runtime,
            model: model,
            enableWebSearch: enableWebSearch,
            enableImageGeneration: enableImageGeneration,
            reasoningEffort: reasoningEffort,
            persistenceAdapter: persistenceAdapter,
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
        enableImageGeneration: Bool = false,
        reasoningEffort: ReasoningEffort = .low,
        persistenceAdapter: DemoPersistenceAdapter = .sqlite,
        keychainAccount: String = defaultKeychainAccount,
        approvalInbox: ApprovalInbox,
        deviceCodePromptCoordinator: DeviceCodePromptCoordinator
    ) throws -> AgentRuntime {
        let diagnostics = DemoDiagnostics()
        let sdkLogging = diagnostics.sdkLoggingConfiguration()
        let authProvider: ChatGPTAuthProvider
        let stateStore = try makeStateStore(
            persistenceAdapter: persistenceAdapter,
            logging: sdkLogging
        )
        let memoryStore = try makeMemoryStore(
            persistenceAdapter: persistenceAdapter,
            logging: sdkLogging
        )

        switch authenticationMethod {
        case .deviceCode:
            authProvider = try ChatGPTAuthProvider(
                method: .deviceCode,
                deviceCodePresenter: deviceCodePromptCoordinator
            )

        case .browserOAuth:
            authProvider = try ChatGPTAuthProvider(
                method: .oauth
            )
        }

        return try AgentRuntime(configuration: .init(
            authProvider: authProvider,
            secureStore: KeychainSessionSecureStore(
                service: "AssistantRuntimeDemoApp.ChatGPTSession",
                account: keychainAccount
            ),
            backend: CodexResponsesBackend(
                configuration: CodexResponsesBackendConfiguration(
                    model: model,
                    reasoningEffort: reasoningEffort,
                    enableReasoningSummaries: true,
                    enableWebSearch: enableWebSearch,
                    enableImageGeneration: enableImageGeneration,
                    logging: sdkLogging
                )
            ),
            approvalPresenter: approvalInbox,
            stateStore: stateStore,
            logging: sdkLogging,
            memory: .init(
                store: memoryStore,
                automaticCapturePolicy: .init(
                    source: .lastTurn,
                    options: .init(
                        defaults: .init(
                            namespace: DemoMemoryExamples.namespace,
                            category: "preference",
                            tags: ["demo", "auto-capture"]
                        ),
                        maxMemories: 2
                    )
                )
            ),
            contextCompaction: AgentContextCompactionConfiguration(
                isEnabled: true,
                mode: .automatic,
                visibility: .hidden,
                strategy: .preferRemoteThenLocal,
                trigger: .init(
                    estimatedTokenThreshold: 2_000,
                    retryOnContextLimitError: true
                )
            ),
            backgroundActivityProvider: interactiveBackgroundActivityProvider()
        ))
    }
    #endif

    static func makeRestorableRuntimeForSystemIntegration(
        model: String = defaultModel,
        enableWebSearch: Bool = true,
        enableImageGeneration: Bool = true,
        reasoningEffort: ReasoningEffort = .low,
        keychainAccount: String = defaultKeychainAccount
    ) throws -> AgentRuntime {
        let diagnostics = DemoDiagnostics()
        let sdkLogging = diagnostics.sdkLoggingConfiguration()
        let authProvider = try ChatGPTAuthProvider(method: .oauth)
        let persistenceAdapter = initialPersistenceAdapter()
        let stateStore = try makeStateStore(
            persistenceAdapter: persistenceAdapter,
            logging: sdkLogging
        )
        let memoryStore = try makeMemoryStore(
            persistenceAdapter: persistenceAdapter,
            logging: sdkLogging
        )

        return try AgentRuntime(configuration: .init(
            authProvider: authProvider,
            secureStore: KeychainSessionSecureStore(
                service: "AssistantRuntimeDemoApp.ChatGPTSession",
                account: keychainAccount
            ),
            backend: CodexResponsesBackend(
                configuration: CodexResponsesBackendConfiguration(
                    model: model,
                    reasoningEffort: reasoningEffort,
                    enableWebSearch: enableWebSearch,
                    enableImageGeneration: enableImageGeneration,
                    logging: sdkLogging
                )
            ),
            approvalPresenter: NonInteractiveApprovalPresenter(),
            stateStore: stateStore,
            logging: sdkLogging,
            memory: .init(
                store: memoryStore,
                automaticCapturePolicy: .init(
                    source: .lastTurn,
                    options: .init(
                        defaults: .init(
                            namespace: DemoMemoryExamples.namespace,
                            category: "preference",
                            tags: ["demo", "auto-capture"]
                        ),
                        maxMemories: 2
                    )
                )
            ),
            contextCompaction: AgentContextCompactionConfiguration(
                isEnabled: true,
                mode: .automatic,
                visibility: .hidden,
                strategy: .preferRemoteThenLocal,
                trigger: .init(
                    estimatedTokenThreshold: 2_000,
                    retryOnContextLimitError: true
                )
            )
        ))
    }

    static func initialPersistenceAdapter(
        userDefaults: UserDefaults = .standard
    ) -> DemoPersistenceAdapter {
        guard let rawValue = userDefaults.string(forKey: persistenceAdapterDefaultsKey),
              let adapter = DemoPersistenceAdapter(rawValue: rawValue)
        else {
            return .sqlite
        }
        return adapter
    }

    static func interactiveBackgroundActivityProvider() -> any AgentBackgroundActivityProviding {
        #if os(iOS)
        IOSBackgroundActivityProvider()
        #else
        NoOpAgentBackgroundActivityProvider()
        #endif
    }

    static func persistPersistenceAdapter(
        _ adapter: DemoPersistenceAdapter,
        userDefaults: UserDefaults = .standard
    ) {
        userDefaults.set(adapter.rawValue, forKey: persistenceAdapterDefaultsKey)
    }

    static func makeStateStore(
        persistenceAdapter: DemoPersistenceAdapter,
        logging: AgentLoggingConfiguration = .disabled
    ) throws -> any RuntimeStateStoring {
        switch persistenceAdapter {
        case .sqlite:
            return try SQLiteRuntimeStateStore(logging: logging)
        case .realm:
            return try RealmRuntimeStateStore(logging: logging)
        }
    }

    static func makeMemoryStore(
        persistenceAdapter: DemoPersistenceAdapter,
        logging: AgentLoggingConfiguration = .disabled
    ) throws -> any MemoryStoring {
        switch persistenceAdapter {
        case .sqlite:
            return try SQLiteMemoryStore(logging: logging)
        case .realm:
            return try RealmMemoryStore(logging: logging)
        }
    }
}

private struct NonInteractiveApprovalPresenter: ApprovalPresenting {
    func requestApproval(_ request: ApprovalRequest) async throws -> ApprovalDecision {
        .denied
    }
}
