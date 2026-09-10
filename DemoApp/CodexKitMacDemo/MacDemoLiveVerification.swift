#if DEBUG
import AppKit
import CodexKit
import CryptoKit
import Foundation

/// Explicit opt-in only: sends one live typed request using the selected on-disk Codex session.
@MainActor
enum MacDemoLiveVerification {
    /// Checks the demo's saved OAuth session without signing out or exposing credentials.
    static func restoreApplicationSession() async {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--verification-result"), args.indices.contains(index + 1) else {
            NSApplication.shared.terminate(nil)
            return
        }
        let suite = "org.codexkit.application-check.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let liveChat = args.contains("--send-live-request")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codexkit-oauth-check-\(UUID())")
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        defaults.set(try? JSONEncoder().encode(MacDemoAuthenticationPreference.application),
                     forKey: MacDemoStorage.preferenceKey)
        let keychain = KeychainSessionSecureStore(service: "CodexKitMacDemo.ApplicationSession", account: "demo")
        let before = try? keychain.loadSession()
        let model = MacDemoModel(preferences: defaults, storageRoot: liveChat ? root : nil)
        model.runtimeOptions.webSearch = false
        model.runtimeOptions.imageGeneration = false
        await model.restore()
        if liveChat, model.isConnected { await model.sendMessage("Reply exactly CODEXKIT_OAUTH_SESSION_OK") }
        let replied = model.chat?.messages.contains(where: {
            $0.role == .assistant && $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == "CODEXKIT_OAUTH_SESSION_OK"
        }) == true
        let unchanged = before != nil && before == (try? keychain.loadSession())
        let report: [String: Any] = ["passed": model.isConnected && (!liveChat || replied) && unchanged,
            "authenticated": model.authentication.status == .connected,
            "liveReplyVerified": replied, "savedCredentialsUnchanged": unchanged,
            "error": model.errorMessage ?? model.chat?.lastError ?? ""]
        do { try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: args[index + 1])) }
        catch { NSLog("Could not write application session verification result.") }
        NSApplication.shared.terminate(nil)
    }

    static func run() async {
        let args = CommandLine.arguments
        func argument(_ name: String) -> String? {
            guard let index = args.firstIndex(of: name), args.indices.contains(index + 1) else { return nil }
            return args[index + 1]
        }
        guard let home = argument("--live-codex-home"), let output = argument("--verification-result") else {
            NSApplication.shared.terminate(nil)
            return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codexkit-live-check-\(UUID())")
        let suite = "org.codexkit.live-check.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let model = MacDemoModel(preferences: defaults, storageRoot: root)
        var report: [String: Any]
        do {
            let credentialURL = URL(fileURLWithPath: home).appendingPathComponent("auth.json")
            let before = SHA256.hash(data: try Data(contentsOf: credentialURL))
            model.localSettings.home = home
            model.localSettings.storage = .file
            try await model.connectLocal()
            guard model.isConnected, let features = model.features else { throw MacDemoError.restoration }
            await features.execute(.shipping)
            guard features.error == nil, !features.structuredPayload.isEmpty,
                  model.chat?.messages.contains(where: { $0.role == .assistant }) == true else {
                throw MacDemoFeatureError(features.error ?? "The live typed result did not commit.")
            }
            await model.disconnect()
            let unchanged = before == SHA256.hash(data: try Data(contentsOf: credentialURL))
            report = ["passed": unchanged, "connectedWithoutSignIn": true, "typedShippingReplyCommitted": true,
                      "ownerCredentialsUnchanged": unchanged, "model": model.modelID]
        } catch {
            await model.disconnect()
            // Do not serialize raw errors or credential/account data into the report.
            report = ["passed": false, "error": "Live session or typed-output verification failed."]
        }
        do { try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: output)) }
        catch { NSLog("Could not write the live verification result.") }
        NSApplication.shared.terminate(nil)
    }
}
#endif
