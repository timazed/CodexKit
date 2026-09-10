import CodexKit
import CryptoKit
import Foundation

/// The demo deliberately asks for the owner's effective settings; it is not a TOML/MDM resolver.
struct MacDemoLocalSettings: Codable, Equatable, Sendable {
    var home = CodexLocalSessionConfiguration.selectedHome(
        environment: ProcessInfo.processInfo.environment,
        userHome: FileManager.default.homeDirectoryForCurrentUser
    ).path
    var storage: CodexCredentialStorage?
    var keyringBackend: CodexAuthKeyringBackend = .direct
    var forcedLoginMethod = ""
    var workspaceID = ""
    var baseURL = "https://chatgpt.com/backend-api"

    func configuration() throws -> CodexLocalSessionConfiguration {
        let path = (home as NSString).expandingTildeInPath
        guard path.hasPrefix("/"), let storage, let url = URL(string: baseURL),
              url.scheme == "https", url.host != nil else {
            throw MacDemoError.settings
        }
        return .init(codexHome: URL(fileURLWithPath: path, isDirectory: true), storage: storage,
                     keyringBackend: keyringBackend,
                     forcedLoginMethod: forcedLoginMethod.isEmpty ? nil : forcedLoginMethod,
                     allowedWorkspaceIDs: workspaceID.isEmpty ? nil : [workspaceID], chatGPTBaseURL: url)
    }
}

enum MacDemoAuthenticationPreference: Codable {
    case disconnected
    case application
    case local(settings: MacDemoLocalSettings, binding: ChatGPTSessionBinding)
}

enum MacDemoError: LocalizedError {
    case settings
    case restoration
    case workspace(String)

    var errorDescription: String? {
        switch self {
        case .settings: "Select credential storage and enter an absolute Codex home path and valid HTTPS endpoint."
        case .restoration: "The saved session could not be restored. Connect again to continue."
        case let .workspace(reason): "Could not open the chat workspace: \(reason)"
        }
    }
}

enum MacDemoStorage {
    static let preferenceKey = "authenticationPreference.v1"

    static func stateURL(root: URL, binding: ChatGPTSessionBinding) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(binding)
        let partition = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let directory = root.appendingPathComponent(partition, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return directory.appendingPathComponent("runtime-state.json")
    }
}
