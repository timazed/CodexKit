import CodexKit
import CodexKitUI
import Foundation
import Observation

@MainActor
@Observable
final class MacDemoModel {
    var localSettings = MacDemoLocalSettings()
    var settingsConfirmed = false
    var composer = ""
    var modelID = CodexModel.gpt56Sol.rawValue
    var models: [CodexAvailableModel] = []
    var errorMessage: String?
    var isBusy = false
    var isSending = false
    var isOfflineDemo = false
    var runtimeOptions = MacDemoRuntimeOptions()
    var reasoningEffort: ReasoningEffort = .low
    var persona: MacDemoPersona = .general
    var useMemory = false
    var reviewerOverride = false
    var pendingImages: [AgentImageAttachment] = []
    var selectedSection = MacDemoSection.assistant
    private(set) var features: MacDemoFeatures?
    var isWorking: Bool { isBusy || isSending || features?.isBusy == true }
    var supportedReasoningEfforts: [ReasoningEffort] {
        models.first { $0.id == modelID }?.supportedReasoningEfforts
            ?? CodexModel(rawValue: modelID).info?.supportedReasoningEfforts ?? ReasoningEffort.allCases
    }
    private(set) var authentication = ChatGPTAuthenticationState(status: .disconnected, externallyManaged: false)
    private(set) var chat: AgentRuntimeStore?
    let deviceCode = DeviceCodePromptCoordinator()
    let approvals = ApprovalInbox()

    @ObservationIgnored private(set) var sessions: ChatGPTSessionManager?
    @ObservationIgnored private(set) var runtime: AgentRuntime?
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var sendTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var hasRestored = false
    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private let storageRoot: URL
    @ObservationIgnored private let sessionStore: any ChatGPTSessionStoring
    @ObservationIgnored private let backend: (any AgentBackend)?

    init(preferences: UserDefaults = .standard, storageRoot: URL? = nil,
         sessionStore: any ChatGPTSessionStoring = KeychainSessionSecureStore(
            service: "CodexKitMacDemo.ApplicationSession", account: "demo"),
         backend: (any AgentBackend)? = nil) {
        self.preferences = preferences
        self.storageRoot = storageRoot ?? FileManager.default.urls(for: .applicationSupportDirectory,
            in: .userDomainMask)[0].appendingPathComponent("CodexKitMacDemo", isDirectory: true)
        self.sessionStore = sessionStore
        self.backend = backend
        if let data = preferences.data(forKey: "runtimeOptions.v1"),
           let saved = try? JSONDecoder().decode(MacDemoRuntimeOptions.self, from: data) { runtimeOptions = saved }
    }

    var isConnected: Bool { authentication.status == .connected && chat != nil }

    var statusText: String {
        if authentication.status == .connected && chat == nil {
            return isBusy ? "Opening workspace…" : "Signed in — workspace unavailable"
        }
        return switch authentication.status {
        case .connected: authentication.externallyManaged ? "Using local Codex session" : "Signed in with ChatGPT"
        case .disconnected: "Disconnected"
        case .reconnectRequired: "Reconnect required"
        case .unavailable: "Session unavailable"
        }
    }

    func restore() async {
        guard !hasRestored else { return }
        hasRestored = true
        guard let data = preferences.data(forKey: MacDemoStorage.preferenceKey) else { return }
        isBusy = true
        let expected = generation
        defer { if expected == generation { isBusy = false } }
        do {
            switch try JSONDecoder().decode(MacDemoAuthenticationPreference.self, from: data) {
            case .disconnected: return
            case .application:
                try await restoreApplicationWorkspace()
            case let .local(settings, binding):
                localSettings = settings
                settingsConfirmed = true
                try await connectLocal(expectedBinding: binding)
            }
        } catch { await report(error, expected: expected) }
    }

    func startLocalConnection() {
        guard settingsConfirmed, !isBusy, !isSending, !isConnected else { return }
        startOperation {
            var binding: ChatGPTSessionBinding?
            if let data = self.preferences.data(forKey: MacDemoStorage.preferenceKey),
               case let .local(_, savedBinding) = try JSONDecoder().decode(MacDemoAuthenticationPreference.self, from: data) {
                binding = savedBinding
            }
            try await self.connectLocal(expectedBinding: binding)
        }
    }

    func startSignIn(method: ChatGPTAuthenticationMethod = .deviceCode) {
        guard !isBusy, !isSending, !isConnected, !isOfflineDemo else { return }
        startOperation {
            let expected = self.generation
            let manager = try self.makeManager(method: method)
            self.sessions = manager
            _ = try await manager.signIn()
            try self.validate(expected)
            try await self.completeApplicationSignIn(using: manager)
        }
    }

    /// Authentication has completed. Persist that choice even if opening local data fails.
    func completeApplicationSignIn(using manager: ChatGPTSessionManager) async throws {
        let expected = generation
        let session = try await manager.requireSession()
        try validate(expected)
        sessions = manager
        authentication = await manager.authenticationState()
        try validate(expected)
        try save(.application)
        try await attach(session, manager: manager, expected: expected)
    }

    func retryWorkspace() {
        guard !isWorking, !isConnected, !isOfflineDemo else { return }
        startOperation {
            let expected = self.generation
            guard let manager = self.sessions, let session = await manager.currentSession() else {
                throw MacDemoError.restoration
            }
            try await self.attach(session, manager: manager, expected: expected)
        }
    }

    func openSavedApplicationSession() {
        guard !isWorking, !isConnected, !isOfflineDemo else { return }
        startOperation { try await self.restoreApplicationWorkspace() }
    }

    private func restoreApplicationWorkspace() async throws {
        let expected = generation
        let manager = try makeManager(method: .oauth)
        sessions = manager
        guard try await manager.restore() != nil else { throw MacDemoError.restoration }
        try validate(expected)
        try await completeApplicationSignIn(using: manager)
    }

    /// A fresh connection is explicit; restoration always supplies the previously accepted binding.
    func connectLocal(expectedBinding: ChatGPTSessionBinding? = nil) async throws {
        let expected = generation
        let selected = localSettings
        let configuration = try selected.configuration()
        let manager = try makeManager()
        sessions = manager
        let source = CodexLocalSessionSource(configuration: { configuration })
        let session = try await manager.connectExternalSession(source: source, expectedBinding: expectedBinding)
        try validate(expected)
        try save(.local(settings: selected, binding: session.binding))
        try await attach(session, manager: manager, expected: expected)
    }

    func disconnect() async {
        generation = UUID()
        operation?.cancel()
        sendTask?.cancel()
        features?.cancel()
        features = nil
        pendingImages = []
        let oldRuntime = runtime
        let oldSessions = sessions
        chat = nil
        runtime = nil
        sessions = nil
        models = []
        composer = ""
        isSending = false
        isBusy = true
        errorMessage = nil
        authentication = .init(status: .disconnected, externallyManaged: false)
        defer { isBusy = false }
        do {
            // Save first so relaunch cannot rediscover a deliberately disconnected session.
            try save(.disconnected)
            if let oldRuntime { try await oldRuntime.signOut() }
            else { try await oldSessions?.signOut() }
        } catch { errorMessage = "Disconnect failed: \(error.localizedDescription)" }
        await deviceCode.clear()
    }

    func checkSession() async {
        guard let sessions, !isBusy else { return }
        let expected = generation
        do {
            _ = try await sessions.requireSession()
            let state = await sessions.authenticationState()
            guard expected == generation else { return }
            authentication = state
        } catch { await report(error, expected: expected) }
    }

    func newConversation() async {
        guard isConnected, !isWorking, let chat, let runtime else { return }
        do {
            let thread = try await runtime.createThread(title: "New conversation",
                configuration: .init(model: modelID, reasoningEffort: reasoningEffort),
                personaStack: persona.stack, skillIDs: persona == .travel ? ["travel_planner"] : [],
                memoryContext: useMemory ? MacDemoRuntimeFactory.memoryContext : nil)
            await chat.activateThread(id: thread.id)
        } catch { await report(error, expected: generation) }
    }

    func selectConversation(_ id: String) async {
        guard isConnected, !isWorking else { return }
        await chat?.activateThread(id: id)
        if let configuration = chat?.activeThread?.configuration {
            modelID = configuration.model
            reasoningEffort = configuration.reasoningEffort
        }
        useMemory = chat?.activeThread?.memoryContext != nil
    }

    func send() {
        guard !isWorking, isConnected,
              !composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingImages.isEmpty else { return }
        let text = composer
        let images = pendingImages
        composer = ""
        pendingImages = []
        isSending = true
        sendTask = Task { await sendMessage(text, images: images) }
    }

    func sendMessage(_ text: String, images: [AgentImageAttachment] = []) async {
        guard isConnected, let chat, let runtime else { isSending = false; return }
        let expected = generation
        isSending = true
        defer { if expected == generation { isSending = false } }
        do {
            if chat.activeThread == nil {
                let thread = try await runtime.createThread(title: text.isEmpty ? "Image conversation" : String(text.prefix(60)),
                    configuration: .init(model: modelID, reasoningEffort: reasoningEffort), personaStack: persona.stack,
                    skillIDs: persona == .travel ? ["travel_planner"] : [],
                    memoryContext: useMemory ? MacDemoRuntimeFactory.memoryContext : nil)
                await chat.activateThread(id: thread.id)
            }
            guard let thread = chat.activeThread else { throw MacDemoError.restoration }
            try await runtime.updateThreadConfiguration(.init(model: modelID, reasoningEffort: reasoningEffort), for: thread.id)
            try await runtime.setMemoryContext(useMemory ? MacDemoRuntimeFactory.memoryContext : nil, for: thread.id)
            chat.dismissError()
            await chat.send(Request(text: text, images: images,
                personaOverride: reviewerOverride ? MacDemoRuntimeFactory.reviewer : nil))
            try validate(expected)
            await checkSession()
        } catch { await report(error, expected: expected) }
    }

    func stop() async {
        if features?.isBusy == true { await features?.stop() }
        await chat?.interrupt()
        sendTask?.cancel()
    }

    func refreshModels() async {
        guard let runtime, isConnected, !isBusy else { return }
        let expected = generation
        isBusy = true
        defer { if expected == generation { isBusy = false } }
        do {
            let catalog = try await runtime.listModels(policy: .refresh)
            guard expected == generation else { return }
            models = catalog.visibleModels
        } catch { await report(error, expected: expected) }
    }

    private func makeManager(method: ChatGPTAuthenticationMethod = .deviceCode) throws -> ChatGPTSessionManager {
        let provider = try ChatGPTAuthProvider(method: method, deviceCodePresenter: deviceCode)
        return ChatGPTSessionManager(authProvider: provider, sessionStore: sessionStore)
    }

    private func attach(_ session: ChatGPTSession, manager: ChatGPTSessionManager, expected: UUID) async throws {
        try validate(expected)
        let stateURL = try MacDemoStorage.stateURL(root: storageRoot, binding: session.binding)
        let (stateStore, memoryStore) = try MacDemoRuntimeFactory.stores(at: stateURL, options: runtimeOptions)
        let diagnostics = MacDemoLogSink()
        let logging = AgentLoggingConfiguration(minimumLevel: .info, sink: diagnostics)
        var memory = AgentMemoryConfiguration(store: memoryStore, automaticCapturePolicy: runtimeOptions.automaticMemory
            ? .init(options: .init(defaults: MacDemoRuntimeFactory.memoryDefaults, maxMemories: 2)) : nil)
        memory.authenticationBinding = session.binding
        let backend = self.backend ?? CodexResponsesBackend(configuration: .init(model: modelID,
            reasoningEffort: reasoningEffort,
            instructions: "You are a helpful assistant embedded in a macOS demo. Use registered tools when useful. Do not assume filesystem or shell access.",
            enableReasoningSummaries: true, enableWebSearch: runtimeOptions.webSearch,
            enableImageGeneration: runtimeOptions.imageGeneration, logging: logging))
        let runtime = try AgentRuntime(configuration: .init(sessionProvider: MacDemoAuthenticatedSessionProvider(manager: manager), backend: backend,
            approvalPresenter: approvals, stateStore: stateStore, logging: logging, memory: memory,
            tools: MacDemoRuntimeFactory.tools, skills: [MacDemoRuntimeFactory.travelSkill],
            contextCompaction: .init(isEnabled: true, mode: .automatic, visibility: .hidden,
                strategy: .preferRemoteThenLocal, trigger: .init(estimatedTokenThreshold: 8_000, retryOnContextLimitError: true))))
        let store = AgentRuntimeStore(runtime: runtime, approvalInbox: approvals, deviceCodeCoordinator: deviceCode)
        await store.restore()
        try validate(expected)
        if let error = store.lastError { throw MacDemoError.workspace(error) }
        guard store.session != nil else { throw MacDemoError.restoration }
        let state = await manager.authenticationState()
        try validate(expected)
        self.runtime = runtime
        chat = store
        if let configuration = store.activeThread?.configuration {
            modelID = configuration.model
            reasoningEffort = configuration.reasoningEffort
        }
        useMemory = store.activeThread?.memoryContext != nil
        features = MacDemoFeatures(runtime: runtime, chat: store, memory: memoryStore, sessions: manager,
            binding: session.binding, diagnostics: diagnostics)
        preferences.set(try JSONEncoder().encode(runtimeOptions), forKey: "runtimeOptions.v1")
        authentication = state
        errorMessage = nil
    }

    private func startOperation(_ action: @escaping @MainActor () async throws -> Void) {
        isBusy = true
        errorMessage = nil
        let expected = generation
        operation = Task {
            defer { if self.generation == expected { self.isBusy = false } }
            do { try await action() }
            catch { await self.report(error, expected: expected) }
        }
    }

    private func validate(_ expected: UUID) throws {
        try Task.checkCancellation()
        guard generation == expected else { throw CancellationError() }
    }

    private func save(_ preference: MacDemoAuthenticationPreference) throws {
        preferences.set(try JSONEncoder().encode(preference), forKey: MacDemoStorage.preferenceKey)
    }

    private func report(_ error: Error, expected: UUID) async {
        guard expected == generation, !(error is CancellationError) else { return }
        let state = await sessions?.authenticationState()
        guard expected == generation else { return }
        authentication = state ?? .init(status: .disconnected, externallyManaged: false)
        errorMessage = error.localizedDescription
        if authentication.status != .connected {
            features?.cancel()
            features = nil
            chat = nil
            models = []
        }
    }
}

/// The demo already restored or acquired credentials before selecting the account's stores.
/// Runtime restoration must reuse that session, without a second Keychain read or lifecycle reset.
private struct MacDemoAuthenticatedSessionProvider: AgentSessionManaging {
    let manager: ChatGPTSessionManager
    func currentSession() async -> ChatGPTSession? { await manager.currentSession() }
    func restore() async throws -> ChatGPTSession? { try await manager.requireSession() }
    func requireSession() async throws -> ChatGPTSession { try await manager.requireSession() }
    func recoverUnauthorizedSession(previousAccessToken: String?) async throws -> ChatGPTSession {
        try await manager.recoverUnauthorizedSession(previousAccessToken: previousAccessToken)
    }
    func signIn() async throws -> ChatGPTSession { try await manager.signIn() }
    func useSession(_ session: ChatGPTSession) async throws -> ChatGPTSession { try await manager.useSession(session) }
    func signOut() async throws { try await manager.signOut() }
}
