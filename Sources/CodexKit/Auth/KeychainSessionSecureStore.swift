import Foundation
import Security

public final class KeychainSessionSecureStore: Sendable {
    private let service: String
    private let account: String

    public init(
        service: String = "CodexKit.ChatGPTSession",
        account: String = "default"
    ) {
        self.service = service
        self.account = account
    }

    public func loadSession() throws -> ChatGPTSession? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw AgentRuntimeError(
                    code: "keychain_invalid_payload",
                    message: "Keychain returned an unexpected session payload."
                )
            }
            return try JSONDecoder().decode(ChatGPTSession.self, from: data)
        case errSecItemNotFound:
            return nil
        default:
            throw AgentRuntimeError(
                code: "keychain_read_failed",
                message: "Failed to read the stored ChatGPT session from Keychain."
            )
        }
    }

    public func saveSession(_ session: ChatGPTSession) throws {
        guard !session.isExternallyManaged else { throw ChatGPTSessionError.unsupportedAuthentication }
        let data = try JSONEncoder().encode(session)
        var attributes = baseQuery()
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return
        }

        guard addStatus == errSecDuplicateItem else {
            throw AgentRuntimeError(
                code: "keychain_write_failed",
                message: "Failed to store the ChatGPT session in Keychain."
            )
        }

        let updateStatus = SecItemUpdate(
            baseQuery() as CFDictionary,
            [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ] as CFDictionary
        )

        guard updateStatus == errSecSuccess else {
            throw AgentRuntimeError(
                code: "keychain_update_failed",
                message: "Failed to update the ChatGPT session in Keychain."
            )
        }
    }

    public func deleteSession() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AgentRuntimeError(
                code: "keychain_delete_failed",
                message: "Failed to remove the ChatGPT session from Keychain."
            )
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
