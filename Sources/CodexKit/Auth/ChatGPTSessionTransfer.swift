import Foundation
import CoreFoundation

/// Fixed, non-secret errors. Validation is local and does not verify provider acceptance.
public enum ChatGPTSessionTransferError: String, Error, LocalizedError, Sendable, CustomStringConvertible {
    case malformed, unsupportedVersion, expired, expiryRequired, reauthenticationRequired
    public var description: String { "ChatGPT session transfer: \(rawValue)" }
    public var errorDescription: String? { description }
}

/// Access-only transfer. Explicit serialization exposes secrets; descriptions never do.
public struct ChatGPTSessionTransfer: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let session: ChatGPTSession
    public var description: String { "ChatGPTSessionTransfer(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }

    public init(session: ChatGPTSession, now: Date = Date()) throws {
        guard let expiry = session.expiresAt else { throw ChatGPTSessionTransferError.expiryRequired }
        var account: [String: Any] = ["id": session.account.id, "plan": session.account.plan.rawValue]
        if !session.account.email.isEmpty { account["email"] = session.account.email }
        if let name = session.account.name { account["name"] = name }
        let object: [String: Any] = ["version": 1, "provider": "chatgpt", "accessToken": session.accessToken,
                                    "expiresAt": floor(expiry.timeIntervalSince1970), "account": account]
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else {
            throw ChatGPTSessionTransferError.malformed
        }
        self = try Self.importJSON(data, now: now)
    }

    public static func importJSON(_ data: Data, now: Date = Date()) throws -> Self {
        guard data.count <= 65_536,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = integer(object["version"]) else { throw ChatGPTSessionTransferError.malformed }
        guard version == 1 else { throw ChatGPTSessionTransferError.unsupportedVersion }
        guard Set(object.keys) == ["version", "provider", "accessToken", "expiresAt", "account"],
              object["provider"] as? String == "chatgpt",
              let token = string(object["accessToken"], limit: 32_768, ascii: true),
              let expiry = integer(object["expiresAt"]), expiry > 0, expiry <= 253_402_300_799,
              let account = object["account"] as? [String: Any],
              Set(account.keys).isSubset(of: ["id", "email", "name", "plan"]),
              let id = string(account["id"], limit: 1_024, ascii: true) else {
            throw ChatGPTSessionTransferError.malformed
        }
        for key in ["email", "name", "plan"] where account[key] != nil {
            guard string(account[key], limit: 1_024) != nil else { throw ChatGPTSessionTransferError.malformed }
        }
        guard now.timeIntervalSince1970.isFinite else { throw ChatGPTSessionTransferError.malformed }
        guard Double(expiry) > now.timeIntervalSince1970 else { throw ChatGPTSessionTransferError.expired }
        let metadata = ChatGPTAccount(id: id, email: account["email"] as? String ?? "",
                                      plan: ChatGPTPlanType(rawValue: account["plan"] as? String ?? "") ?? .unknown,
                                      name: account["name"] as? String)
        return Self(validated: ChatGPTSession(accessToken: token, account: metadata,
                    binding: .init(sourceID: "codexkit:session-transfer:v1", accountID: id),
                    expiresAt: Date(timeIntervalSince1970: Double(expiry)), acquiredAt: now))
    }

    private init(validated: ChatGPTSession) { session = validated }

    /// Sensitive plaintext JSON. Send over authenticated TLS and encrypt at rest; never log it.
    public func exportJSON(now: Date = Date()) throws -> Data {
        _ = try validatedSession(now: now)
        var account: [String: Any] = ["id": session.account.id, "plan": session.account.plan.rawValue]
        if !session.account.email.isEmpty { account["email"] = session.account.email }
        if let name = session.account.name { account["name"] = name }
        return try JSONSerialization.data(withJSONObject: ["version": 1, "provider": "chatgpt",
            "accessToken": session.accessToken, "expiresAt": session.expiresAt!.timeIntervalSince1970,
            "account": account], options: [.sortedKeys])
    }

    /// Explicit credential access, checked immediately before use. No refresh or network activity.
    public func validatedSession(now: Date = Date()) throws -> ChatGPTSession {
        guard now.timeIntervalSince1970.isFinite else { throw ChatGPTSessionTransferError.malformed }
        guard session.expiresAt! > now else { throw ChatGPTSessionTransferError.expired }
        return session
    }

    private static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let d = number.doubleValue
        guard d.isFinite, d >= 0, d <= 253_402_300_799, floor(d) == d else { return nil }
        return Int64(d)
    }

    private static func string(_ value: Any?, limit: Int, ascii: Bool = false) -> String? {
        guard let value = value as? String, !value.isEmpty, value.utf8.count <= limit,
              value.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 && (!ascii || $0.value < 127) }),
              !ascii || !value.contains(" ") else { return nil }
        return value
    }
}

extension ChatGPTSession {
    var isTransferred: Bool { isExternallyManaged && binding.sourceID == "codexkit:session-transfer:v1" }
}
