import SwiftUI

@main
struct CodexKitMacDemoApp: App {
    @NSApplicationDelegateAdaptor(MacDemoAppDelegate.self) private var delegate
    @State private var model = MacDemoModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        Window("CodexKit for macOS", id: "main") {
            MacDemoView(model: model)
                .frame(minWidth: 880, minHeight: 620)
                .task {
                    #if DEBUG
                    if CommandLine.arguments.contains("--verify-local-only") || CommandLine.arguments.contains("--verify-live-local")
                        || CommandLine.arguments.contains("--verify-application-session") {
                        return
                    }
                    if CommandLine.arguments.contains("--offline-demo") {
                        do { model = try await MacDemoVerification.makePreview() }
                        catch { model.errorMessage = "Could not start the offline demo." }
                        return
                    }
                    #endif
                    await model.restore()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await model.checkSession() } }
                }
        }
        .defaultSize(width: 1060, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Conversation") { Task { await model.newConversation() } }
                    .keyboardShortcut("n")
                    .disabled(!model.isConnected || model.isSending)
            }
        }
    }
}

@MainActor
final class MacDemoAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if CommandLine.arguments.contains("--verify-local-only") {
            // Verification must run even when macOS restores this instance with no visible window.
            Task { await MacDemoVerification.run() }
        } else if CommandLine.arguments.contains("--verify-live-local") {
            Task { await MacDemoLiveVerification.run() }
        } else if CommandLine.arguments.contains("--verify-application-session") {
            Task { await MacDemoLiveVerification.restoreApplicationSession() }
        }
        #endif
    }
}
