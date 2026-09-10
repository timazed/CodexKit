// Synthetic signed-macOS smoke test. Never reads a user's Codex home or existing credentials.
import CodexKit
import CryptoKit
import Foundation
import Security

@main
struct VerifyLocalCodexSession {
    static func main() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("CodexKitFixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let canonical = home.resolvingSymlinksInPath().path
        let digest = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Codex Auth", kSecAttrAccount as String: "cli|" + digest.prefix(16)]
        let claims: [String: Any] = ["exp": Int(Date().addingTimeInterval(3600).timeIntervalSince1970),
            "https://api.openai.com/auth": ["chatgpt_account_id": "synthetic-workspace", "chatgpt_user_id": "synthetic-user"]]
        let encoded = try JSONSerialization.data(withJSONObject: claims).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let token = "eyJhbGciOiJub25lIn0." + encoded + ".synthetic"
        let payload = try JSONSerialization.data(withJSONObject: ["auth_mode": "chatgpt", "tokens": [
            "access_token": token, "id_token": token, "refresh_token": "SYNTHETIC-OWNER-ONLY", "account_id": "synthetic-workspace"]])
        let file = home.appendingPathComponent("auth.json")
        try payload.write(to: file)
        var attributes = query
        attributes[kSecValueData as String] = payload
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw VerificationFailure.failed("Synthetic Keychain setup failed") }
        defer { SecItemDelete(query as CFDictionary) }
        let reader = MacOSCodexCredentialReader()
        for storage in [CodexCredentialStorage.file, .keyring, .auto] {
            let source = CodexLocalSessionSource(configuration: { .init(codexHome: home, storage: storage) })
            let manager = ChatGPTSessionManager(authProvider: try ChatGPTAuthProvider(method: .oauth),
                secureStore: .init(service: "CodexKit.SyntheticVerification", account: UUID().uuidString))
            let session = try await manager.connectExternalSession(source: source)
            guard session.refreshToken == nil, session.idToken == nil else { throw VerificationFailure.failed("Owner secrets retained") }
            try await manager.signOut()
            guard try Data(contentsOf: file) == payload,
                  try reader.readKeychain(service: "Codex Auth", account: "cli|" + digest.prefix(16)) == payload else {
                throw VerificationFailure.failed("External fixture changed")
            }
        }
        print("Signed macOS discovery/disconnect passed for synthetic file, Keychain, and auto storage.")
    }
}

private enum VerificationFailure: Error { case failed(String) }
