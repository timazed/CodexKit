import Foundation
import Security

public final class KeychainSessionSecureStore: SessionSecureStoring, @unchecked Sendable {
    private let service: String
    private let account: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        service: String = "AssistantRuntimeKit.ChatGPTSession",
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
                throw AssistantRuntimeError(
                    code: "keychain_invalid_payload",
                    message: "Keychain returned an unexpected session payload."
                )
            }
            return try decoder.decode(ChatGPTSession.self, from: data)
        case errSecItemNotFound:
            return nil
        default:
            throw AssistantRuntimeError(
                code: "keychain_read_failed",
                message: "Failed to read the stored ChatGPT session from Keychain."
            )
        }
    }

    public func saveSession(_ session: ChatGPTSession) throws {
        let data = try encoder.encode(session)
        var attributes = baseQuery()
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return
        }

        guard addStatus == errSecDuplicateItem else {
            throw AssistantRuntimeError(
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
            throw AssistantRuntimeError(
                code: "keychain_update_failed",
                message: "Failed to update the ChatGPT session in Keychain."
            )
        }
    }

    public func deleteSession() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AssistantRuntimeError(
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
