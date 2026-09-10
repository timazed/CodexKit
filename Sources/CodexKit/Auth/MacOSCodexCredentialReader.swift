#if os(macOS)
import Foundation
import LocalAuthentication
import Security

/// Uses the caller's existing filesystem/Keychain permissions. Never prompts during background reads.
public struct MacOSCodexCredentialReader: CodexCredentialReading {
    public init() {}

    public func canonicalHome(_ home: URL) throws -> URL {
        home.standardizedFileURL.resolvingSymlinksInPath()
    }

    public func readFile(_ url: URL) throws -> Data? {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 1_048_577) ?? Data()
            guard data.count <= 1_048_576 else { throw ChatGPTSessionError.malformedCredentials }
            return data
        } catch let error as ChatGPTSessionError { throw error }
        catch {
            let value = error as NSError
            if value.domain == NSCocoaErrorDomain && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(value.code) { return nil }
            if value.domain == NSCocoaErrorDomain && value.code == NSFileReadNoPermissionError { throw ChatGPTSessionError.accessDenied }
            if value.domain == NSPOSIXErrorDomain && value.code == ENOENT { return nil }
            if value.domain == NSPOSIXErrorDomain && [EACCES, EPERM].contains(Int32(value.code)) { throw ChatGPTSessionError.accessDenied }
            throw ChatGPTSessionError.storageUnavailable
        }
    }

    public func readKeychain(service: String, account: String) throws -> Data? {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]
        var result: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &result) {
        case errSecSuccess:
            guard let data = result as? Data else { throw ChatGPTSessionError.malformedCredentials }
            return data
        case errSecItemNotFound: return nil
        case errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled, errSecMissingEntitlement:
            throw ChatGPTSessionError.accessDenied
        case errSecNotAvailable: throw ChatGPTSessionError.storageUnavailable
        default: throw ChatGPTSessionError.accessDenied
        }
    }
}

extension CodexLocalSessionSource {
    public init(configuration: @escaping @Sendable () async throws -> CodexLocalSessionConfiguration,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.init(configuration: configuration, reader: MacOSCodexCredentialReader(), now: now)
    }
}
#endif
