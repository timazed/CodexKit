import Foundation
import Observation
import CodexKit
import CodexKitSQLite
import CodexKitUI

@MainActor
@Observable
final class ChatViewModel {
    private(set) var store: AgentRuntimeStore?
    private(set) var setupError: String?
    private(set) var isBusy = false
    private(set) var isSending = false
    var draft = ""
    private var isStarting = false

    var canSend: Bool {
        store?.session != nil && !isBusy &&
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func start() async {
        guard store == nil, !isStarting else { return }
        isStarting = true
        setupError = nil
        defer { isStarting = false }
        do {
            let approvals = ApprovalInbox()
            let deviceCode = DeviceCodePromptCoordinator()
            let runtime = try AgentRuntime(configuration: .init(
                authProvider: try ChatGPTAuthProvider(
                    method: .deviceCode,
                    deviceCodePresenter: deviceCode
                ),
                secureStore: KeychainSessionSecureStore(
                    service: "MyChatApp.ChatGPTSession",
                    account: "main"
                ),
                backend: CodexResponsesBackend(configuration: .init(
                    model: .gpt56Sol,
                    reasoningEffort: .low
                )),
                approvalPresenter: approvals,
                stateStore: try SQLiteRuntimeStateStore()
            ))
            try await runtime.registerTool(
                ToolDefinition(
                    name: "project_status",
                    description: "Read the current project's status.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([:]),
                        "additionalProperties": .bool(false)
                    ]),
                    approvalPolicy: .requiresApproval,
                    approvalMessage: "Share the current project status with the assistant?"
                ),
                executor: AnyToolExecutor { invocation, _ in
                    // Replace this sample result with an authorized read from your app.
                    .success(invocation: invocation, text: "Sample project: 3 tasks remaining.")
                }
            )
            let prepared = AgentRuntimeStore(
                runtime: runtime,
                approvalInbox: approvals,
                deviceCodeCoordinator: deviceCode
            )
            await prepared.restore()
            try Task.checkCancellation()
            store = prepared
        } catch is CancellationError {
            // A later appearance can retry startup.
        } catch {
            setupError = error.localizedDescription
        }
    }

    func signIn() { perform { await $0.signIn() } }
    func signOut() { perform { await $0.signOut() } }
    func newConversation() { perform { await $0.createThread(title: "Conversation") } }
    func selectConversation(id: String) {
        perform { await $0.activateThread(id: id) }
    }

    func send() {
        guard canSend else { return }
        let text = draft
        draft = ""
        isSending = true
        perform { store in
            defer { self.isSending = false }
            await store.send(text)
        }
    }

    func stop() {
        guard let store, isSending else { return }
        Task { await store.interrupt() }
    }

    func approveTool() { store?.approvalInbox?.approveCurrent() }
    func denyTool() { store?.approvalInbox?.denyCurrent() }
    func dismissError() { store?.dismissError() }

    private func perform(_ operation: @escaping @MainActor (AgentRuntimeStore) async -> Void) {
        guard let store, !isBusy else { return }
        isBusy = true
        Task {
            defer { isBusy = false }
            await operation(store)
        }
    }
}
