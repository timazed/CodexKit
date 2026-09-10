import AppKit
import CodexKit
import SwiftUI

struct MacDemoConnectionView: View {
    @Bindable var model: MacDemoModel
    @Environment(\.openURL) private var openURL
    @State private var showsAdvanced = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "desktopcomputer").font(.system(size: 32)).foregroundStyle(.tint)
                    Text("Connect to CodexKit").font(.largeTitle.weight(.semibold))
                    Text("Use your existing local Codex session or sign in with ChatGPT to start chatting.")
                        .foregroundStyle(.secondary)
                }
                if model.authentication.status == .reconnectRequired {
                    Text("Sign in again in Codex if its session expired, then reconnect here. To switch accounts, disconnect first.")
                        .foregroundStyle(.secondary)
                }
                if model.authentication.status == .connected {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("You’re signed in. The chat workspace could not open.").font(.headline)
                            Text("Retry opening your conversations with the current session.")
                                .foregroundStyle(.secondary)
                            Button("Retry Opening Workspace") { model.retryWorkspace() }
                                .buttonStyle(.borderedProminent).disabled(model.isWorking)
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Use local Codex session").font(.headline)
                        Text("Choose the same home and credential settings your Codex installation uses.")
                            .font(.callout).foregroundStyle(.secondary)
                        HStack {
                            TextField("Codex home", text: $model.localSettings.home).textFieldStyle(.roundedBorder)
                            Button("Choose…", action: chooseHome)
                        }
                        Picker("Credential storage", selection: $model.localSettings.storage) {
                            Text("Select storage…").tag(nil as CodexCredentialStorage?)
                            Text("File (auth.json)").tag(CodexCredentialStorage.file as CodexCredentialStorage?)
                            Text("macOS Keychain").tag(CodexCredentialStorage.keyring as CodexCredentialStorage?)
                            Text("Auto (Keychain, then file)").tag(CodexCredentialStorage.auto as CodexCredentialStorage?)
                        }
                        DisclosureGroup("Advanced Codex settings", isExpanded: $showsAdvanced) {
                            VStack(alignment: .leading, spacing: 12) {
                                Picker("Keyring backend", selection: $model.localSettings.keyringBackend) {
                                    Text("Direct").tag(CodexAuthKeyringBackend.direct)
                                    Text("Secrets (unsupported)").tag(CodexAuthKeyringBackend.secrets)
                                }
                                TextField("Forced login method (optional)", text: $model.localSettings.forcedLoginMethod)
                                TextField("Required workspace ID (optional)", text: $model.localSettings.workspaceID)
                                TextField("ChatGPT endpoint", text: $model.localSettings.baseURL)
                                Text("Match effective settings, including command-line and managed overrides. This demo does not resolve Codex configuration files.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .textFieldStyle(.roundedBorder).padding(.top, 10)
                        }
                        Toggle("These match my Codex settings", isOn: $model.settingsConfirmed)
                        Button("Connect Local Session") { model.startLocalConnection() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!model.settingsConfirmed || model.localSettings.storage == nil)
                        Text("Credentials stay in Codex. Disconnecting here leaves Codex signed in.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .disabled(model.isBusy || model.isSending)
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Sign in with ChatGPT").font(.headline)
                        Text("Give this demo its own session using your browser or a device code.")
                            .font(.callout).foregroundStyle(.secondary)
                        HStack {
                            Button("Sign In with Browser OAuth") { model.startSignIn(method: .oauth) }
                                .buttonStyle(.borderedProminent)
                            Button("Use Device Code") { model.startSignIn(method: .deviceCode) }
                        }.disabled(model.isBusy || model.isSending || model.isOfflineDemo)
                        Button("Open Saved ChatGPT Session") { model.openSavedApplicationSession() }
                            .disabled(model.isWorking || model.isOfflineDemo)
                        Text("Browser sign-in uses a local callback on port 1455. Cancel to stop waiting for sign-in.")
                            .font(.caption).foregroundStyle(.secondary)
                        if let prompt = model.deviceCode.currentPrompt {
                            Text(prompt.userCode).font(.title.monospaced()).textSelection(.enabled)
                            Button("Open Verification Page") { openURL(prompt.verificationURL) }
                            Text("Enter this code in your browser, then return here.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("Session options") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Persistence", selection: $model.runtimeOptions.persistence) {
                            ForEach(MacDemoPersistence.allCases) { Text($0.title).tag($0) }
                        }
                        Text("Each adapter keeps separate conversations and memory for this account. Existing File conversations remain available by selecting File.")
                            .font(.caption).foregroundStyle(.secondary)
                        Toggle("Web search", isOn: $model.runtimeOptions.webSearch)
                        Toggle("Image generation", isOn: $model.runtimeOptions.imageGeneration)
                        Toggle("Automatically capture memory after turns", isOn: $model.runtimeOptions.automaticMemory)
                        Text("Automatic capture applies to conversations with Use Memory enabled.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(10).disabled(model.isBusy)
                }
                if model.isBusy {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Connecting…")
                        Spacer()
                        Button("Cancel") { Task { await model.disconnect() } }
                    }
                } else if model.sessions != nil || model.authentication.status != .disconnected {
                    Button("Disconnect") { Task { await model.disconnect() } }
                }
            }
            .padding(32).frame(maxWidth: 640).frame(maxWidth: .infinity)
        }
        .onChange(of: model.localSettings) { _, _ in model.settingsConfirmed = false }
    }

    private func chooseHome() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.prompt = "Choose Codex Home"
        if panel.runModal() == .OK, let url = panel.url { model.localSettings.home = url.path }
    }
}
