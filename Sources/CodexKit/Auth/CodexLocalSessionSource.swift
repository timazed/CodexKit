import CryptoKit
import Foundation

public enum CodexCredentialStorage: String, Codable, Sendable { case file, keyring, auto, ephemeral }
public enum CodexAuthKeyringBackend: String, Codable, Sendable { case direct, secrets }

/// Supply the owner's EFFECTIVE configuration, including CLI overrides and managed requirements.
/// Storage is required deliberately: guessing defaults can select an obsolete account.
public struct CodexLocalSessionConfiguration: Sendable, Equatable {
    public let codexHome: URL
    public let storage: CodexCredentialStorage
    public let keyringBackend: CodexAuthKeyringBackend
    public let forcedLoginMethod: String?
    public let allowedWorkspaceIDs: [String]?
    public let chatGPTBaseURL: URL

    public init(codexHome: URL, storage: CodexCredentialStorage,
                keyringBackend: CodexAuthKeyringBackend = .direct,
                forcedLoginMethod: String? = nil, allowedWorkspaceIDs: [String]? = nil,
                chatGPTBaseURL: URL = URL(string: "https://chatgpt.com/backend-api")!) {
        self.codexHome = codexHome
        self.storage = storage
        self.keyringBackend = keyringBackend
        self.forcedLoginMethod = forcedLoginMethod
        self.allowedWorkspaceIDs = allowedWorkspaceIDs
        self.chatGPTBaseURL = chatGPTBaseURL
    }

    /// GUI hosts should pass their selected home explicitly; shell environment may differ.
    public static func selectedHome(environment: [String: String], userHome: URL) -> URL {
        if let path = environment["CODEX_HOME"], !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }
        return userHome.appendingPathComponent(".codex", isDirectory: true)
    }
}

/// Every operation is read-only. Injectable implementations make discovery testable without real credentials.
public protocol CodexCredentialReading: Sendable {
    func canonicalHome(_ home: URL) throws -> URL
    func readFile(_ url: URL) throws -> Data?
    func readKeychain(service: String, account: String) throws -> Data?
}

/// Resolves local ChatGPT credentials without retaining or rotating their refresh token.
/// Configuration is resolved again on every read, so hosts can report owner configuration changes.
public actor CodexLocalSessionSource: ChatGPTExternalSessionSource {
    private let configuration: @Sendable () async throws -> CodexLocalSessionConfiguration
    private let reader: any CodexCredentialReading
    private let now: @Sendable () -> Date
    private var selectedConfiguration: CodexLocalSessionConfiguration?
    private var selectedStorage: CodexCredentialStorage?

    public init(configuration: @escaping @Sendable () async throws -> CodexLocalSessionConfiguration,
                reader: any CodexCredentialReading, now: @escaping @Sendable () -> Date = { Date() }) {
        self.configuration = configuration
        self.reader = reader
        self.now = now
    }

    /// Discovery reports expired credentials; `resolve` also returns expired snapshots for owner renewal.
    public func discover() async throws -> ChatGPTSession {
        let session = try await resolve()
        guard !session.requiresRefresh(referenceDate: now()) else { throw ChatGPTSessionError.expiredCredentials }
        return session
    }

    public func resolve() async throws -> ChatGPTSession {
        do {
            let config = try await configuration()
            try Task.checkCancellation()
            if let selectedConfiguration, selectedConfiguration != config { throw ChatGPTSessionError.configurationChanged }
            guard config.forcedLoginMethod == nil || config.forcedLoginMethod == "chatgpt",
                  config.chatGPTBaseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    == "https://chatgpt.com/backend-api" else { throw ChatGPTSessionError.unsupportedAuthentication }
            guard config.codexHome.isFileURL else { throw ChatGPTSessionError.unsupportedStorage }
            guard config.storage != .ephemeral else { throw ChatGPTSessionError.storageUnavailable }
            guard config.storage == .file || config.keyringBackend == .direct else { throw ChatGPTSessionError.unsupportedStorage }
            let home = try reader.canonicalHome(config.codexHome)
            let key = "cli|" + String(Self.digest(home.path).prefix(16))
            let (data, storage) = try read(config: config, home: home, key: key)
            if let selectedStorage, selectedStorage != storage { throw ChatGPTSessionError.configurationChanged }
            guard let data else { throw ChatGPTSessionError.missingCredentials }
            guard data.count <= 1_048_576 else { throw ChatGPTSessionError.malformedCredentials }
            let sourceID = "codex:" + Self.digest(home.path + "|" + config.storage.rawValue + "|" + storage.rawValue)
            let session = try CodexStoredCredentials.decode(data, sourceID: sourceID, now: now())
            if let allowed = config.allowedWorkspaceIDs, !allowed.contains(session.account.id) {
                throw ChatGPTSessionError.accountChanged
            }
            selectedConfiguration = config
            selectedStorage = storage
            return session
        } catch is CancellationError { throw CancellationError() }
        catch let error as ChatGPTSessionError { throw error }
        catch { throw ChatGPTSessionError.transientFailure }
    }

    private func read(config: CodexLocalSessionConfiguration, home: URL, key: String) throws -> (Data?, CodexCredentialStorage) {
        switch config.storage {
        case .file: return (try reader.readFile(home.appendingPathComponent("auth.json")), .file)
        case .keyring: return (try reader.readKeychain(service: "Codex Auth", account: key), .keyring)
        case .auto:
            do {
                if let data = try reader.readKeychain(service: "Codex Auth", account: key) { return (data, .keyring) }
            } catch ChatGPTSessionError.storageUnavailable {
                // Deliberately do not mask denial or malformed data by selecting a fallback account.
            }
            if selectedStorage == .keyring { throw ChatGPTSessionError.missingCredentials }
            return (try reader.readFile(home.appendingPathComponent("auth.json")), .file)
        case .ephemeral: throw ChatGPTSessionError.storageUnavailable
        }
    }

    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

private struct CodexStoredCredentials: Decodable {
    let auth_mode: String?
    let OPENAI_API_KEY: String?
    let tokens: Tokens?
    let agent_identity: JSONValue?
    let personal_access_token: String?
    let bedrock_api_key: JSONValue?
    let bedrock_access_keys: JSONValue?

    struct Tokens: Decodable {
        let access_token: String
        let id_token: String
        let account_id: String?
        // The refresh token is intentionally not decoded or retained.
    }

    struct Claims: Decodable {
        let exp: Double?
        let email: String?
        let name: String?
        let auth: Auth?
        let profile: Profile?
        enum CodingKeys: String, CodingKey {
            case exp, email, name
            case auth = "https://api.openai.com/auth"
            case profile = "https://api.openai.com/profile"
        }
        struct Profile: Decodable { let email: String? }
        struct Auth: Decodable {
            let chatgpt_account_id: String?
            let chatgpt_user_id: String?
            let user_id: String?
            let chatgpt_plan_type: String?
            let chatgpt_account_is_fedramp: Bool?
            var userID: String? { chatgpt_user_id ?? user_id }
        }
    }

    static func decode(_ data: Data, sourceID: String, now: Date) throws -> ChatGPTSession {
        do {
            let stored = try JSONDecoder().decode(Self.self, from: data)
            guard stored.auth_mode == nil || stored.auth_mode == "chatgpt",
                  stored.OPENAI_API_KEY == nil, stored.agent_identity == nil,
                  stored.personal_access_token == nil, stored.bedrock_api_key == nil,
                  stored.bedrock_access_keys == nil else { throw ChatGPTSessionError.unsupportedAuthentication }
            guard let tokens = stored.tokens, !tokens.access_token.isEmpty else { throw ChatGPTSessionError.malformedCredentials }
            let access = try claims(tokens.access_token)
            let identity = try claims(tokens.id_token)
            guard let expiry = access.exp, expiry.isFinite, expiry > 0,
                  let account = tokens.account_id ?? identity.auth?.chatgpt_account_id ?? access.auth?.chatgpt_account_id,
                  !account.isEmpty,
                  let userID = identity.auth?.userID ?? access.auth?.userID, !userID.isEmpty else {
                throw ChatGPTSessionError.malformedCredentials
            }
            for claim in [identity.auth, access.auth].compactMap({ $0 }) {
                if let id = claim.chatgpt_account_id, id != account { throw ChatGPTSessionError.accountChanged }
                if let id = claim.userID, id != userID { throw ChatGPTSessionError.accountChanged }
                if claim.chatgpt_account_is_fedramp == true { throw ChatGPTSessionError.unsupportedAuthentication }
            }
            return ChatGPTSession(accessToken: tokens.access_token,
                account: .init(id: account, email: identity.email ?? identity.profile?.email ?? "",
                               plan: ChatGPTPlanType(rawValue: identity.auth?.chatgpt_plan_type ?? "") ?? .unknown,
                               name: identity.name),
                binding: .init(sourceID: sourceID, accountID: account, userID: userID),
                expiresAt: Date(timeIntervalSince1970: expiry), acquiredAt: now,
                credentialGeneration: CodexLocalSessionSource.digest(tokens.access_token))
        } catch let error as ChatGPTSessionError { throw error }
        catch { throw ChatGPTSessionError.malformedCredentials }
    }

    private static func claims(_ token: String) throws -> Claims {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[0].isEmpty, !parts[1].isEmpty else { throw ChatGPTSessionError.malformedCredentials }
        var value = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        guard let data = Data(base64Encoded: value) else { throw ChatGPTSessionError.malformedCredentials }
        return try JSONDecoder().decode(Claims.self, from: data)
    }
}
