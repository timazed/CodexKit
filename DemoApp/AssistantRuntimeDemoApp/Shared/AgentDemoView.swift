import CodexKit
import CodexKitUI
import Foundation
import Observation
import SwiftUI

@available(iOS 17.0, macOS 14.0, *)
struct AgentDemoView: View {
    @State private var viewModel: AgentDemoViewModel

    init(viewModel: AgentDemoViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        VStack(spacing: 16) {
            header
            threadStrip
            messageTranscript
            composer
        }
        .padding(20)
        .task {
            await viewModel.restore()
            await viewModel.registerDemoTool()
        }
        .sheet(item: approvalRequestBinding) { request in
            approvalSheet(for: request)
        }
        .sheet(item: deviceCodePromptBinding) { prompt in
            deviceCodeSheet(for: prompt)
        }
        .alert("Runtime Error", isPresented: errorBinding) {
            Button("Dismiss") {
                viewModel.dismissError()
            }
        } message: {
            Text(viewModel.lastError ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Agent Runtime Demo")
                    .font(.title2.weight(.semibold))

                if let session = viewModel.session {
                    Text("Signed in as \(session.account.email)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Sign in with ChatGPT to start a live thread.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button("Register Tool") {
                Task {
                    await viewModel.registerDemoTool()
                }
            }
            .buttonStyle(.bordered)

            Button(viewModel.session == nil ? "Sign In" : "New Thread") {
                Task {
                    if viewModel.session == nil {
                        await viewModel.signIn()
                    } else {
                        await viewModel.createThread()
                    }
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var threadStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(viewModel.threads) { thread in
                    Button {
                        Task {
                            await viewModel.activateThread(id: thread.id)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(thread.title ?? "Untitled Thread")
                                .font(.subheadline.weight(.medium))
                            Text(thread.status.rawValue)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(thread.id == viewModel.activeThread?.id ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var messageTranscript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(viewModel.messages) { message in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(message.role.rawValue.capitalized)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(message.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(message.role == .user ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.08))
                    )
                }

                if !viewModel.streamingText.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Assistant")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(viewModel.streamingText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color.secondary.opacity(0.08))
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var composer: some View {
        HStack(spacing: 12) {
            TextField("Message the agent", text: $viewModel.composerText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1 ... 4)

            Button("Send") {
                Task {
                    await viewModel.sendComposerText()
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var approvalRequestBinding: Binding<ApprovalRequest?> {
        Binding(
            get: { viewModel.approvalInbox.currentRequest },
            set: { _ in }
        )
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.lastError != nil },
            set: { isPresented in
                if !isPresented {
                    viewModel.dismissError()
                }
            }
        )
    }

    private var deviceCodePromptBinding: Binding<ChatGPTDeviceCodePrompt?> {
        Binding(
            get: { viewModel.deviceCodePromptCoordinator.currentPrompt },
            set: { _ in }
        )
    }

    @ViewBuilder
    private func approvalSheet(for request: ApprovalRequest) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(request.title)
                .font(.title3.weight(.semibold))

            Text(request.message)
                .foregroundStyle(.secondary)

            if case let .object(arguments) = request.toolInvocation.arguments {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Arguments")
                        .font(.headline)
                    ForEach(arguments.keys.sorted(), id: \.self) { key in
                        Text("\(key): \(String(describing: arguments[key]))")
                            .font(.subheadline)
                    }
                }
            }

            HStack {
                Button("Deny") {
                    viewModel.denyPendingRequest()
                }
                .buttonStyle(.bordered)

                Button("Approve") {
                    viewModel.approvePendingRequest()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .presentationDetents([.medium])
    }

    @ViewBuilder
    private func deviceCodeSheet(for prompt: ChatGPTDeviceCodePrompt) -> some View {
        DeviceCodePromptView(prompt: prompt)
            .presentationDetents([.medium, .large])
    }
}

@available(iOS 17.0, macOS 14.0, *)
private struct DeviceCodePromptView: View {
    let prompt: ChatGPTDeviceCodePrompt

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Finish Sign-In")
                .font(.title3.weight(.semibold))

            Text("Open the verification page, sign in with ChatGPT, and enter this one-time code.")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text("Code")
                    .font(.headline)
                Text(prompt.userCode)
                    .font(.system(.title2, design: .monospaced).weight(.semibold))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color.secondary.opacity(0.10))
                    )
            }

            HStack(spacing: 12) {
                Button("Open Verification Page") {
                    openURL(prompt.verificationURL)
                }
                .buttonStyle(.borderedProminent)
            }

            Text(prompt.verificationURL.absoluteString)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            Spacer()
        }
        .padding(24)
    }
}
