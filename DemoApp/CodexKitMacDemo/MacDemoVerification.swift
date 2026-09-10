#if DEBUG
import AppKit
import CodexKit
import Foundation

/// Runs inside the signed app. All credentials, defaults, and conversations are isolated fixtures.
@MainActor
enum MacDemoVerification {
    static func run() async {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--verification-result"), arguments.indices.contains(index + 1) else {
            NSApplication.shared.terminate(nil)
            return
        }
        let resultURL = URL(fileURLWithPath: arguments[index + 1])
        let smoke = arguments.contains("--verify-smoke")
        var result: [String: Any]
        do {
            let directory = resultURL.deletingLastPathComponent().appendingPathComponent("recovery")
            let checks: [String]
            if arguments.contains("--verify-recovery-reopen") {
                checks = try await DemoRecoveryVerification.reopen(directory: directory)
            } else {
                let existing = try await verify(smoke: smoke)
                checks = existing + (try await DemoRecoveryVerification.run(directory: directory, smoke: smoke))
            }
            result = ["passed": true, "checks": checks]
        } catch {
            result = ["passed": false, "error": error.localizedDescription]
        }
        result["mode"] = smoke ? "smoke" : "full"
        result["phase"] = arguments.contains("--verify-recovery-reopen") ? "reopen" : "initial"
        result["runID"] = ProcessInfo.processInfo.environment["CODEXKIT_VERIFICATION_RUN_ID"] ?? UUID().uuidString
        do { try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: resultURL) }
        catch { NSLog("Could not write demo verification result.") }
        NSApplication.shared.terminate(nil)
    }

    private static func verify(smoke: Bool) async throws -> [String] {
        let fixture = try MacDemoFixture()
        defer { fixture.cleanup() }
        var checks: [String] = []
        let model = fixture.makeModel()
        await model.restore()
        try require(!model.isConnected, "Fresh launch should wait for explicit connection")
        checks.append("fresh launch does not discover credentials")

        try await model.connectLocal()
        try require(model.isConnected && model.authentication.externallyManaged, "Local connection failed")
        let ownerData = try Data(contentsOf: fixture.authURL)
        try require(fixture.secureStore.loadSession() == nil, "Borrowed credentials were persisted")
        checks.append("local discovery without copying credentials")

        await model.sendMessage("Hello from the macOS smoke test")
        try require(model.chat?.lastError == nil, "Chat reported an error")
        try require(model.chat?.messages.contains(where: { $0.role == .assistant && $0.text.contains("Offline reply") }) == true,
                    "Streaming reply was not committed")
        guard let thread = model.chat?.activeThread else { throw VerificationError("No saved conversation") }
        checks.append("streaming chat commits a reply")

        let restored = fixture.makeModel()
        await restored.restore()
        try require(restored.isConnected, "Saved local session did not restore")
        await restored.selectConversation(thread.id)
        try require(restored.chat?.messages.contains(where: { $0.role == .assistant }) == true,
                    "Saved messages did not restore")
        checks.append("bound session and conversation restore")

        if smoke {
            let request = Task { await restored.sendMessage("slow response") }
            try await Task.sleep(for: .milliseconds(100))
            await restored.disconnect()
            await request.value
            try require(restored.chat == nil && !restored.isConnected, "Late response restored disconnected UI")
            checks.append("disconnect during streaming cannot restore UI")
            return checks
        }

        // A renewed token from the same owner remains usable without reconnecting.
        try fixture.writeCredentials(account: "synthetic-workspace", nonce: "rotated")
        await restored.checkSession()
        try require(restored.isConnected, "Same-account token rotation failed")
        checks.append("same-account credential rotation")

        try fixture.writeCredentials(account: "another-workspace")
        await restored.checkSession()
        try require(!restored.isConnected && restored.chat == nil, "Account change retained visible chat")
        let wrongAccount = fixture.makeModel()
        await wrongAccount.restore()
        try require(!wrongAccount.isConnected, "Restoration silently switched accounts")
        checks.append("account changes hide chat and block restoration")

        try ownerData.write(to: fixture.authURL, options: .atomic)
        await model.disconnect()
        try require(try Data(contentsOf: fixture.authURL) == ownerData, "Disconnect changed the owner's credentials")
        let disconnected = fixture.makeModel()
        await disconnected.restore()
        try require(!disconnected.isConnected && disconnected.sessions == nil,
                    "Disconnected preference reconnected on relaunch")
        checks.append("disconnect preserves owner credentials and survives relaunch")

        try await disconnected.connectLocal()
        let request = Task { await disconnected.sendMessage("slow response") }
        try await Task.sleep(for: .milliseconds(100))
        await disconnected.disconnect()
        await request.value
        try require(disconnected.chat == nil && !disconnected.isConnected, "Late response restored disconnected UI")
        checks.append("disconnect during streaming cannot restore UI")

        try fixture.writeCredentials(account: "synthetic-workspace", expiry: Date().addingTimeInterval(-60))
        let expired = fixture.makeModel()
        do { try await expired.connectLocal(); throw VerificationError("Expired credentials were accepted") }
        catch is ChatGPTSessionError { }
        checks.append("expired credentials require reconnect")

        try Data("not json".utf8).write(to: fixture.authURL)
        let malformed = fixture.makeModel()
        do { try await malformed.connectLocal(); throw VerificationError("Malformed credentials were accepted") }
        catch ChatGPTSessionError.malformedCredentials { }
        checks.append("malformed credentials fail safely")

        // App-owned restoration exercises the separate persistence partition and sign-out path.
        fixture.secureStore.saveSession(ChatGPTSession(accessToken: "synthetic-app-token",
            account: .init(id: "app-workspace", email: "demo@example.invalid", plan: .plus),
            expiresAt: Date().addingTimeInterval(3600)))
        fixture.defaults.set(try JSONEncoder().encode(MacDemoAuthenticationPreference.application),
                             forKey: MacDemoStorage.preferenceKey)
        let application = fixture.makeModel()
        await application.restore()
        try require(application.isConnected && !application.authentication.externallyManaged, "App-owned restore failed")
        try require(application.chat?.threads.isEmpty == true, "Conversations crossed account partitions")
        await application.disconnect()
        try require(fixture.secureStore.loadSession() == nil, "App-owned sign-out did not remove its credentials")
        checks.append("app-owned restoration, account isolation, and sign-out")
        checks += try await verifyApplicationHandoff()
        checks += try await verifyFeatures(fixture)
        return checks
    }

    private static func verifyApplicationHandoff() async throws -> [String] {
        let fixture = try MacDemoFixture()
        defer { fixture.cleanup() }
        let keychain = KeychainSessionSecureStore(service: "CodexKitMacDemo.Verification.\(UUID())", account: "oauth")
        defer { try? keychain.deleteSession() }
        let store = MacDemoCountingSessionStore(base: keychain)
        let manager = ChatGPTSessionManager(authProvider: try ChatGPTAuthProvider(method: .oauth), sessionStore: store)
        let session = ChatGPTSession(accessToken: "synthetic-oauth-token", refreshToken: "synthetic-refresh",
            account: .init(id: "oauth-workspace", email: "demo@example.invalid", plan: .plus),
            expiresAt: Date().addingTimeInterval(3600))
        // Start at the OAuth completion boundary, after tokens have been saved to native Keychain.
        _ = try await manager.useSession(session)
        func makeModel() -> MacDemoModel {
            MacDemoModel(preferences: fixture.defaults, storageRoot: fixture.root.appendingPathComponent("state"),
                sessionStore: store, backend: MacDemoOfflineBackend())
        }
        let model = makeModel()
        store.rejectReads = true
        try await model.completeApplicationSignIn(using: manager)
        try require(model.isConnected && store.readCount == 0, "OAuth handoff reread Keychain")
        await model.sendMessage("Verify the signed-in workspace")
        try require(model.chat?.messages.last?.role == .assistant, "OAuth handoff did not enable chat")
        store.rejectReads = false
        let relaunched = makeModel()
        await relaunched.restore()
        try require(relaunched.isConnected && store.readCount == 1, "Relaunch must read native Keychain exactly once")
        fixture.defaults.removeObject(forKey: MacDemoStorage.preferenceKey)
        let saved = makeModel()
        await saved.restore()
        try require(!saved.isConnected && store.readCount == 1, "Fresh launch discovered saved credentials automatically")
        saved.openSavedApplicationSession()
        for _ in 0..<200 {
            if !saved.isBusy { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try require(saved.isConnected && store.readCount == 2, "Explicit saved-session recovery failed")

        let stateURL = try MacDemoStorage.stateURL(root: fixture.root.appendingPathComponent("broken-state"), binding: session.binding)
        try Data("broken workspace fixture".utf8).write(to: stateURL)
        func makeBrokenModel() -> MacDemoModel {
            MacDemoModel(preferences: fixture.defaults, storageRoot: fixture.root.appendingPathComponent("broken-state"),
                sessionStore: store, backend: MacDemoOfflineBackend())
        }
        fixture.defaults.removeObject(forKey: MacDemoStorage.preferenceKey)
        let broken = makeBrokenModel()
        do {
            try await broken.completeApplicationSignIn(using: manager)
            throw VerificationError("Broken workspace unexpectedly opened")
        } catch MacDemoError.workspace { }
        try require(!broken.isConnected && broken.authentication.status == .connected
            && broken.statusText.contains("workspace unavailable"), "Workspace failure misreported authentication")
        let failedRelaunch = makeBrokenModel()
        await failedRelaunch.restore()
        try require(failedRelaunch.authentication.status == .connected
            && failedRelaunch.errorMessage?.hasPrefix("Could not open the chat workspace:") == true,
            "Failed handoff lost its saved authentication choice or underlying error")
        try FileManager.default.removeItem(at: stateURL)
        let readsBeforeRetry = store.readCount
        store.rejectReads = true
        failedRelaunch.retryWorkspace()
        for _ in 0..<200 {
            if !failedRelaunch.isBusy { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try require(failedRelaunch.isConnected && failedRelaunch.errorMessage == nil
            && store.readCount == readsBeforeRetry, "Workspace retry reacquired credentials or failed")
        try require(try keychain.loadSession() == session, "Workspace retry changed saved credentials")
        return ["OAuth completion opens chat without rereading Keychain",
                "OAuth relaunch restores native Keychain once",
                "explicit saved-session recovery works without a saved authentication preference",
                "workspace failure preserves sign-in and reports the underlying error",
                "workspace retry reuses authentication and preserves Keychain credentials"]
    }

    private static func verifyFeatures(_ fixture: MacDemoFixture) async throws -> [String] {
        try fixture.writeCredentials(account: "synthetic-workspace")
        var checks: [String] = []
        for adapter in MacDemoPersistence.allCases {
            let model = fixture.makeModel()
            model.runtimeOptions.persistence = adapter
            try await model.connectLocal()
            guard let features = model.features else { throw VerificationError("Missing features") }
            features.memoryText = "Persisted preference for \(adapter.rawValue)"
            await features.execute(.saveMemory)
            try require(features.error == nil && !features.memories.isEmpty, "Memory save failed for \(adapter)")
            features.memoryQuery = "Persisted preference"
            await features.execute(.queryMemory)
            try require(features.error == nil && !features.memories.isEmpty, "Memory query failed for \(adapter)")
            await model.sendMessage("Persist this conversation")
            let restored = fixture.makeModel()
            await restored.restore()
            try require(restored.isConnected && restored.chat?.threads.isEmpty == false, "Adapter restoration failed")
            restored.features?.memoryQuery = "Persisted preference"
            await restored.features?.execute(.queryMemory)
            try require(restored.features?.memories.isEmpty == false, "Memory did not persist on \(adapter)")
            checks.append("\(adapter.title) conversations and memory persist in the account partition")

            if adapter == .file {
                for action in [MacDemoAction.shipping, .imported, .streamed] {
                    await features.execute(action)
                    try require(features.error == nil && !features.structuredPayload.isEmpty, "Typed output failed: \(action)")
                }
                try require(features.partialCount > 0 && model.chat?.messages.last?.structuredOutput != nil,
                            "Streamed payload metadata was not committed")
                checks.append("typed shipping, imported content, and streamed structured payloads")
                await features.execute(.ephemeral)
                try require(features.error == nil, "Ephemeral reply failed")
                await features.execute(.previewMemory)
                try require(features.error == nil && features.memoryPreview.contains("Persisted preference"), "Memory prompt preview failed")
                checks.append("ephemeral replies and bound memory prompt preview")
                await features.execute(.parallel)
                try require(features.error == nil && model.chat?.peakConcurrentTools == 2, "Parallel tools did not overlap")
                checks.append("parallel sample tools execute concurrently")
                let approval = Task { await features.execute(.approval) }
                for _ in 0..<100 {
                    if model.approvals.currentRequest != nil { break }
                    try await Task.sleep(for: .milliseconds(20))
                }
                guard model.approvals.currentRequest != nil else {
                    await model.disconnect()
                    await approval.value
                    throw VerificationError("Approval UI was not requested")
                }
                model.approvals.approveCurrent()
                await approval.value
                try require(features.error == nil, "Approved tool failed")
                checks.append("approval inbox gates the draft tool")
                await features.execute(.travel)
                try require(features.error == nil, "Required travel skill tool failed")
                checks.append("travel skill enforces its tool policy")
                await features.execute(.compact)
                try require(features.error == nil, "Context compaction failed")
                checks.append("context compaction completes")
            }
            await model.disconnect()
        }
        return checks
    }

    static func makePreview() async throws -> MacDemoModel {
        let fixture = try MacDemoFixture()
        // Preview fixtures live only in a temporary directory, cleaned when the app exits.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
            object: nil, queue: nil) { _ in fixture.cleanup() }
        let model = fixture.makeModel()
        model.isOfflineDemo = true
        try await model.connectLocal()
        await model.sendMessage("What can I try in this macOS demo?")
        return model
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw VerificationError(message) }
    }
}

private struct VerificationError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private final class MacDemoFixture: @unchecked Sendable {
    let root: URL
    let defaults: UserDefaults
    let suite: String
    let secureStore = MacDemoMemorySessionStore()
    var authURL: URL { root.appendingPathComponent("codex/auth.json") }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("codexkit-mac-demo-\(UUID())")
        suite = "org.codexkit.mac-demo.fixture.\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        try FileManager.default.createDirectory(at: root.appendingPathComponent("codex"), withIntermediateDirectories: true)
        try writeCredentials(account: "synthetic-workspace")
    }

    @MainActor
    func makeModel() -> MacDemoModel {
        let model = MacDemoModel(preferences: defaults, storageRoot: root.appendingPathComponent("state"),
                                 sessionStore: secureStore, backend: MacDemoOfflineBackend())
        model.localSettings.home = root.appendingPathComponent("codex").path
        model.localSettings.storage = .file
        model.settingsConfirmed = true
        return model
    }

    func writeCredentials(account: String, nonce: String = "original", expiry: Date = Date().addingTimeInterval(3600)) throws {
        let payload: [String: Any] = ["exp": expiry.timeIntervalSince1970, "email": "demo@example.invalid",
            "nonce": nonce, "https://api.openai.com/auth": ["chatgpt_account_id": account, "chatgpt_user_id": "synthetic-user"]]
        let encoded = try JSONSerialization.data(withJSONObject: payload).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let token = "e30.\(encoded).synthetic"
        let data = try JSONSerialization.data(withJSONObject: ["auth_mode": "chatgpt",
            "tokens": ["access_token": token, "id_token": token, "refresh_token": "owner-only", "account_id": account]])
        try data.write(to: authURL, options: .atomic)
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

private final class MacDemoMemorySessionStore: ChatGPTSessionStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: ChatGPTSession?
    func loadSession() -> ChatGPTSession? { lock.withLock { value } }
    func saveSession(_ session: ChatGPTSession) { lock.withLock { value = session } }
    func deleteSession() { lock.withLock { value = nil } }
}

private final class MacDemoCountingSessionStore: ChatGPTSessionStoring, @unchecked Sendable {
    let base: any ChatGPTSessionStoring
    private let lock = NSLock()
    private var reads = 0
    private var rejects = false
    init(base: any ChatGPTSessionStoring) { self.base = base }
    var readCount: Int { lock.withLock { reads } }
    var rejectReads: Bool {
        get { lock.withLock { rejects } }
        set { lock.withLock { rejects = newValue } }
    }
    func loadSession() throws -> ChatGPTSession? {
        let rejected = lock.withLock { reads += 1; return rejects }
        if rejected { throw ChatGPTSessionError.accessDenied }
        return try base.loadSession()
    }
    func saveSession(_ session: ChatGPTSession) throws { try base.saveSession(session) }
    func deleteSession() throws { try base.deleteSession() }
}

private struct MacDemoOfflineBackend: AgentBackend {
    func createThread(session: ChatGPTSession) async throws -> AgentThread { .init(id: UUID().uuidString) }
    func resumeThread(id: String, session: ChatGPTSession) async throws -> AgentThread { .init(id: id) }

    func beginTurn(thread: AgentThread, history: [AgentMessage], message: Request, instructions: String,
                   responseFormat: AgentStructuredOutputFormat?, streamedStructuredOutput: AgentStreamedStructuredOutputRequest?,
                   tools: [ToolDefinition], session: ChatGPTSession) async throws -> AgentTurnStream {
        let results = AsyncStream<ToolResultEnvelope>.makeStream()
        let events = AsyncThrowingStream<AgentBackendEvent, Error> { continuation in
            let worker = Task {
                defer { results.continuation.finish() }
                do {
                    let turn = AgentTurn(id: UUID().uuidString, threadID: thread.id)
                    continuation.yield(.turnStarted(turn))
                    let toolNames: [String]
                    if thread.skillIDs.contains("travel_planner") { toolNames = ["travel_planner_build_day_plan"] }
                    else if message.text.contains("demo_prepare_draft") { toolNames = ["demo_prepare_draft"] }
                    else if message.text.contains("demo_lookup_weather") { toolNames = ["demo_lookup_weather", "demo_lookup_transport"] }
                    else { toolNames = [] }
                    if !toolNames.isEmpty {
                        let invocations = toolNames.map { name in
                            ToolInvocation(id: UUID().uuidString, threadID: thread.id, turnID: turn.id, toolName: name,
                                arguments: name == "travel_planner_build_day_plan" ? .object(["destination": .string("Sydney")]) : .object([:]))
                        }
                        continuation.yield(.toolCallsRequested(invocations))
                        var count = 0
                        for await _ in results.stream {
                            count += 1
                            if count == invocations.count { break }
                        }
                        try Task.checkCancellation()
                    }
                    let format = streamedStructuredOutput?.responseFormat ?? responseFormat
                    let payload = Self.payload(format?.name)
                    let reply = responseFormat != nil && streamedStructuredOutput == nil ? payload :
                        "Offline reply: try chat, tools, structured output, and memory. This preview uses synthetic credentials and makes no network requests."
                    let delay: Duration = message.text == "slow response" ? .seconds(2) : .milliseconds(10)
                    for word in reply.split(separator: " ") {
                        try await Task.sleep(for: delay)
                        continuation.yield(.assistantMessageDelta(threadID: thread.id, turnID: turn.id, delta: "\(word) "))
                    }
                    var metadata: AgentStructuredOutputMetadata?
                    if let format {
                        let value = try JSONDecoder().decode(JSONValue.self, from: Data(payload.utf8))
                        metadata = .init(formatName: format.name, payload: value)
                        if streamedStructuredOutput != nil {
                            continuation.yield(.structuredOutputPartial(value))
                            continuation.yield(.structuredOutputCommitted(value))
                        }
                    }
                    continuation.yield(.assistantMessageCompleted(.init(id: UUID().uuidString, threadID: thread.id,
                        role: .assistant, text: reply, structuredOutput: metadata)))
                    continuation.yield(.turnCompleted(.init(threadID: thread.id, turnID: turn.id)))
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in worker.cancel(); results.continuation.finish() }
        }
        return .init(events: events, submitToolResult: { result, _ in results.continuation.yield(result) })
    }

    private static func payload(_ name: String?) -> String {
        switch name {
        case "shipping_reply_draft": #"{"subject":"Delivery update","reply":"We will check the tracking status.","urgency":"high"}"#
        case "imported_content_summary": #"{"title":"CodexKit","keyPoints":["Streaming","Tools","Memory"],"followUpAction":"Try the demo"}"#
        case "streamed_delivery_update": #"{"statusHeadline":"Delayed","customerPromise":"We will investigate","nextAction":"Check tracking"}"#
        default: #"{"memories":[]}"#
        }
    }
}
#endif
