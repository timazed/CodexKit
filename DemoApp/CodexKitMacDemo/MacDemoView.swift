import AppKit
import CodexKit
import CodexKitUI
import SwiftUI

struct MacDemoView: View {
    @Bindable var model: MacDemoModel

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List {
                    Section("Conversations") {
                        if let chat = model.chat, !chat.threads.isEmpty {
                            ForEach(chat.threads) { thread in
                                Button {
                                    Task { await model.selectConversation(thread.id) }
                                } label: {
                                    Label(thread.title ?? "Untitled conversation", systemImage: "bubble.left")
                                        .lineLimit(2)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.vertical, 5)
                                }
                                .buttonStyle(.plain)
                                .listRowBackground(chat.activeThread?.id == thread.id ? Color.accentColor.opacity(0.14) : .clear)
                                .disabled(model.isWorking || !model.isConnected)
                            }
                        } else {
                            Text("Your conversations appear here.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Label(model.statusText, systemImage: model.isConnected ? "checkmark.circle.fill" : "person.crop.circle")
                        .font(.callout.weight(.medium))
                    if let account = model.chat?.session?.account, !account.displayName.isEmpty {
                        Text(account.displayName).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    if model.isOfflineDemo {
                        Text("Offline demo · synthetic credentials")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if let expiry = model.authentication.expiresAt {
                        Text("Session expires \(expiry.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if model.isConnected {
                        HStack {
                            Button("Check Session") { Task { await model.checkSession() } }
                                .disabled(model.isBusy)
                            Spacer()
                            Button("Disconnect") { Task { await model.disconnect() } }
                        }
                        .controlSize(.small)
                    }
                }
                .padding(16)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 330)
        } detail: {
            VStack(spacing: 0) {
                if let message = model.errorMessage ?? model.chat?.lastError {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                        Text(message).textSelection(.enabled)
                        Spacer()
                        Button {
                            model.errorMessage = nil
                            model.chat?.dismissError()
                        } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel("Dismiss error")
                    }
                    .padding().background(Color.orange.opacity(0.08))
                    Divider()
                }
                if model.isConnected, let chat = model.chat {
                    Picker("Demo", selection: $model.selectedSection) {
                        ForEach(MacDemoSection.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).padding()
                    if model.selectedSection == .assistant {
                        chatContent(chat)
                    } else if let features = model.features {
                        MacDemoFeatureView(model: model, features: features)
                    }
                } else {
                    MacDemoConnectionView(model: model)
                }
            }
            .navigationTitle(model.chat?.activeThread?.title ?? "CodexKit")
            .toolbar {
                ToolbarItem {
                    Button { Task { await model.newConversation() } } label: {
                        Label("New Conversation", systemImage: "square.and.pencil")
                    }
                    .disabled(!model.isConnected || model.isWorking)
                }
            }
        }
        .sheet(item: Binding(get: { model.approvals.currentRequest }, set: { _ in })) { request in
            VStack(alignment: .leading, spacing: 16) {
                Text(request.title).font(.title2.bold())
                Text(request.message)
                Text(request.toolInvocation.arguments.prettyJSONString).font(.callout.monospaced()).textSelection(.enabled)
                HStack {
                    Button("Stop") { Task { await model.stop() } }
                    Spacer()
                    Button("Deny") { model.approvals.denyCurrent() }
                    Button("Approve") { model.approvals.approveCurrent() }.buttonStyle(.borderedProminent)
                }
            }.padding(24).frame(minWidth: 440).interactiveDismissDisabled()
        }
    }

    private func chatContent(_ chat: AgentRuntimeStore) -> some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        if chat.messages.isEmpty && !model.isSending {
                            ContentUnavailableView("Start a conversation", systemImage: "bubble.left.and.bubble.right",
                                description: Text("Send a message to try CodexKit’s streaming runtime."))
                                .frame(maxWidth: .infinity).padding(.top, 90)
                        }
                        ForEach(chat.messages) { message in
                            messageView(role: message.role == .user ? "You" : message.role == .tool ? "Tool" : "Assistant", text: message.displayText)
                            ForEach(message.images) { attachment in
                                if let image = NSImage(data: attachment.data) {
                                    Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 300)
                                }
                            }
                            if let interaction = message.toolInteraction {
                                DisclosureGroup("Tool: \(interaction.invocation.toolName)") {
                                    Text(interaction.result.primaryText ?? "Tool completed").font(.caption.monospaced()).textSelection(.enabled)
                                }
                            }
                        }
                        if !chat.streamingText.isEmpty {
                            messageView(role: "Assistant", text: chat.streamingText)
                        } else if model.isWorking {
                            ProgressView("Working…").controlSize(.small)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(28).frame(maxWidth: 860).frame(maxWidth: .infinity)
                }
                .onChange(of: chat.streamingText) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: chat.messages.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                if !chat.runningTools.isEmpty {
                    Text("Running: " + chat.runningTools.values.sorted().joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                }
                if !chat.reasoningSummary.isEmpty {
                    DisclosureGroup("Reasoning summary") {
                        ScrollView { Text(chat.reasoningSummary).font(.caption).textSelection(.enabled) }.frame(maxHeight: 100)
                    }
                }
                HStack {
                    if model.models.isEmpty {
                        TextField("Model", text: $model.modelID).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                    } else {
                        Picker("Model", selection: $model.modelID) {
                            if !model.models.contains(where: { $0.id == model.modelID }) {
                                Text(model.modelID).tag(model.modelID)
                            }
                            ForEach(model.models) { Text($0.displayName).tag($0.id) }
                        }
                        .frame(maxWidth: 300)
                    }
                    Button("Refresh Models") { Task { await model.refreshModels() } }
                        .disabled(model.isBusy)
                    Spacer()
                    Text("⌘ Return to send").font(.caption).foregroundStyle(.secondary)
                }
                .disabled(model.isWorking)
                HStack {
                    Picker("Reasoning", selection: $model.reasoningEffort) {
                        ForEach(model.supportedReasoningEfforts, id: \.self) { Text($0.rawValue).tag($0) }
                    }.frame(maxWidth: 200)
                    Picker("New conversation", selection: $model.persona) {
                        ForEach(MacDemoPersona.allCases) { Text($0.title).tag($0) }
                    }.frame(maxWidth: 240)
                    Toggle("Use Memory", isOn: $model.useMemory)
                    Toggle("Reviewer override", isOn: $model.reviewerOverride)
                }.controlSize(.small).disabled(model.isWorking)
                if !model.pendingImages.isEmpty {
                    HStack {
                        ForEach(model.pendingImages) { attachment in
                            Button { model.pendingImages.removeAll { $0.id == attachment.id } } label: {
                                if let image = NSImage(data: attachment.data) {
                                    Image(nsImage: image).resizable().scaledToFit().frame(width: 60, height: 45)
                                        .overlay(alignment: .topTrailing) { Image(systemName: "xmark.circle.fill") }
                                }
                            }.help("Remove attachment")
                        }
                    }
                }
                HStack(alignment: .bottom, spacing: 12) {
                    TextField("Message", text: $model.composer, axis: .vertical)
                        .lineLimit(2...6).textFieldStyle(.plain).padding(12)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityIdentifier("messageComposer")
                    Button { model.attachImages() } label: { Image(systemName: "paperclip") }.help("Attach PNG or JPEG images")
                    if model.isSending {
                        Button("Add to Turn") { Task { await model.addToTurn() } }
                        Button("Stop", systemImage: "stop.fill") { Task { await model.stop() } }
                    } else {
                        Button("Send", systemImage: "arrow.up") { model.send() }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.return, modifiers: .command)
                            .disabled((model.composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.pendingImages.isEmpty) || model.isWorking)
                    }
                }
            }
            .padding(20)
        }
        .onChange(of: model.modelID) { _, _ in
            if !model.supportedReasoningEfforts.contains(model.reasoningEffort), let effort = model.supportedReasoningEfforts.first {
                model.reasoningEffort = effort
            }
        }
    }

    private func messageView(role: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(role).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
            Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
