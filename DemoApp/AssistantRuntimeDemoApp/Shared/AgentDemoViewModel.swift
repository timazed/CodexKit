import CodexKit
import CodexKitUI
import Foundation
import Observation

@MainActor
@Observable
final class AgentDemoViewModel: @unchecked Sendable {
    private(set) var session: ChatGPTSession?
    private(set) var threads: [AgentThread] = []
    private(set) var messages: [AgentMessage] = []
    private(set) var streamingText = ""
    private(set) var lastError: String?
    private(set) var isAuthenticating = false
    var composerText = ""

    let approvalInbox: ApprovalInbox
    let deviceCodePromptCoordinator: DeviceCodePromptCoordinator

    private let redirectURI: URL
    private let model: String
    private let stateURL: URL?
    private let keychainAccount: String

    private var runtime: AgentRuntime
    private var activeThreadID: String?

    init(
        runtime: AgentRuntime,
        redirectURI: URL,
        model: String,
        stateURL: URL?,
        keychainAccount: String,
        approvalInbox: ApprovalInbox,
        deviceCodePromptCoordinator: DeviceCodePromptCoordinator = DeviceCodePromptCoordinator()
    ) {
        self.runtime = runtime
        self.redirectURI = redirectURI
        self.model = model
        self.stateURL = stateURL
        self.keychainAccount = keychainAccount
        self.approvalInbox = approvalInbox
        self.deviceCodePromptCoordinator = deviceCodePromptCoordinator
    }

    var activeThread: AgentThread? {
        guard let activeThreadID else {
            return nil
        }
        return threads.first { $0.id == activeThreadID }
    }

    func restore() async {
        do {
            _ = try await runtime.restore()
            await registerDemoTool()
            await refreshSnapshot()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func signIn(using authenticationMethod: DemoAuthenticationMethod) async {
        guard !isAuthenticating else {
            return
        }

        isAuthenticating = true
        lastError = nil
        runtime = AgentDemoRuntimeFactory.makeRuntime(
            authenticationMethod: authenticationMethod,
            redirectURI: redirectURI,
            model: model,
            stateURL: stateURL,
            keychainAccount: keychainAccount,
            approvalInbox: approvalInbox,
            deviceCodePromptCoordinator: deviceCodePromptCoordinator
        )

        defer {
            isAuthenticating = false
        }

        do {
            _ = try await runtime.restore()
            await registerDemoTool()
            session = try await runtime.signIn()
            await refreshSnapshot()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func registerDemoTool() async {
        let definition = ToolDefinition(
            name: "demo_lookup_profile",
            description: "Return a deterministic demo profile payload.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "message": .object(["type": .string("string")]),
                ]),
            ]),
            approvalPolicy: .requiresApproval,
            approvalMessage: "Allow the demo app to run the registered profile lookup tool?"
        )

        do {
            try await runtime.replaceTool(definition, executor: AnyToolExecutor { invocation, _ in
                let requestedMessage: String
                if case let .object(arguments) = invocation.arguments,
                   let message = arguments["message"]?.stringValue {
                    requestedMessage = message
                } else {
                    requestedMessage = "No message"
                }

                return .success(
                    invocation: invocation,
                    text: "profile[name=Taylor, source=demo, input=\(requestedMessage)]"
                )
            })
        } catch {
            lastError = error.localizedDescription
        }
    }

    func createThread() async {
        do {
            let thread = try await runtime.createThread()
            threads = await runtime.threads()
            activeThreadID = thread.id
            messages = await runtime.messages(for: thread.id)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func activateThread(id: String) async {
        activeThreadID = id
        messages = await runtime.messages(for: id)
        streamingText = ""
    }

    func sendComposerText() async {
        guard !composerText.isEmpty else {
            return
        }

        if activeThreadID == nil {
            await createThread()
        }

        guard let activeThreadID else {
            lastError = "No active thread is available."
            return
        }

        let outgoingText = composerText
        composerText = ""
        streamingText = ""

        do {
            let stream = try await runtime.sendMessage(
                UserMessageRequest(text: outgoingText),
                in: activeThreadID
            )
            messages = await runtime.messages(for: activeThreadID)

            for try await event in stream {
                switch event {
                case let .threadStarted(thread):
                    threads = [thread] + threads.filter { $0.id != thread.id }

                case let .threadStatusChanged(threadID, status):
                    threads = threads.map { thread in
                        guard thread.id == threadID else {
                            return thread
                        }
                        var updated = thread
                        updated.status = status
                        updated.updatedAt = Date()
                        return updated
                    }

                case .turnStarted:
                    break

                case let .assistantMessageDelta(_, _, delta):
                    streamingText.append(delta)

                case let .messageCommitted(message):
                    messages.append(message)
                    if message.role == .assistant {
                        streamingText = ""
                    }

                case .approvalRequested:
                    break

                case .approvalResolved:
                    break

                case .toolCallStarted:
                    break

                case .toolCallFinished:
                    break

                case .turnCompleted:
                    messages = await runtime.messages(for: activeThreadID)
                    threads = await runtime.threads()

                case let .turnFailed(error):
                    lastError = error.message
                }
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func approvePendingRequest() {
        approvalInbox.approveCurrent()
    }

    func denyPendingRequest() {
        approvalInbox.denyCurrent()
    }

    func dismissError() {
        lastError = nil
    }

    func signOut() async {
        do {
            try await runtime.signOut()
            await deviceCodePromptCoordinator.clear()
            session = nil
            threads = []
            messages = []
            streamingText = ""
            composerText = ""
            activeThreadID = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func refreshSnapshot() async {
        session = await runtime.currentSession()
        threads = await runtime.threads()

        let selectedThreadID = activeThreadID
        if let selectedThreadID,
           threads.contains(where: { $0.id == selectedThreadID }) {
            messages = await runtime.messages(for: selectedThreadID)
            return
        }

        if let firstThread = threads.first {
            activeThreadID = firstThread.id
            messages = await runtime.messages(for: firstThread.id)
        } else {
            activeThreadID = nil
            messages = []
        }
    }
}
