import SwiftUI
import CodexKitUI

@MainActor
struct ChatView: View {
    @State private var model = ChatViewModel()

    var body: some View {
        Group {
            if let store = model.store {
                content(store: store)
            } else if let error = model.setupError {
                Text(error)
                Button("Retry") { Task { await model.start() } }
            } else {
                ProgressView("Preparing chat…")
            }
        }
        .task { await model.start() }
    }

    private func content(store: AgentRuntimeStore) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if store.session == nil {
                Button("Sign in with ChatGPT") {
                    model.signIn()
                }
                .disabled(model.isBusy)
            } else {
                HStack {
                    Button("New conversation") {
                        model.newConversation()
                    }
                    Button("Sign out") { model.signOut() }
                }
                .disabled(model.isBusy)
                Menu("Saved conversations") {
                    ForEach(store.threads) { thread in
                        Button(thread.title ?? "Conversation") {
                            model.selectConversation(id: thread.id)
                        }
                    }
                }
                .disabled(model.isBusy)
            }

            if let prompt = store.deviceCodeCoordinator?.currentPrompt {
                Text("Enter this code: \(prompt.userCode)")
                    .textSelection(.enabled)
                Link("Continue ChatGPT sign-in", destination: prompt.verificationURL)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(store.messages) { message in
                        Text(message.displayText)
                    }
                    if !store.streamingText.isEmpty {
                        Text(store.streamingText)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let approval = store.approvalInbox?.currentRequest {
                Text(approval.title).bold()
                Text(approval.message)
                HStack {
                    Button("Approve") { model.approveTool() }
                    Button("Deny") { model.denyTool() }
                }
            }

            HStack {
                TextField("Message", text: $model.draft)
                Button("Send") {
                    model.send()
                }
                .disabled(!model.canSend)
                if model.isSending {
                    Button("Stop") { model.stop() }
                }
            }
            if let error = store.lastError {
                Text(error).foregroundStyle(.red)
                Button("Dismiss error") { model.dismissError() }
            }
        }
        .padding()
    }

}
