import CryptoKit
import Foundation

/// Keeps opaque Responses state free of inline image bytes. Images remain in
/// the runtime's attachment-backed message/tool history and are expanded only
/// while constructing an outbound request.
enum CodexResponsesImageReferences {
    private static let dataURLPrefix = "codexkit-image-ref:data-url:"
    private static let base64Prefix = "codexkit-image-ref:base64:"

    static func externalize(_ items: [JSONValue]) throws -> [JSONValue] {
        try items.map(externalize)
    }

    static func restore(
        _ items: [JSONValue],
        using attachments: [AgentImageAttachment]
    ) throws -> [JSONValue] {
        let byDigest = Dictionary(
            attachments.map { (digest($0.data), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return try items.map { try restore($0, using: byDigest) }
    }

    /// Checks attachment ownership without allocating expanded base64 payloads.
    static func validate(_ items: [JSONValue], using attachments: [AgentImageAttachment]) throws {
        var requiredDigests = Set<String>()
        for item in items { collectReferenceDigests(in: item, into: &requiredDigests) }
        guard !requiredDigests.isEmpty else { return }
        for attachment in attachments {
            requiredDigests.remove(digest(attachment.data))
            if requiredDigests.isEmpty { return }
        }
        throw missingImage()
    }

    static func attachments(
        in messages: [AgentMessage],
        additional: [AgentImageAttachment] = []
    ) -> [AgentImageAttachment] {
        var result = additional
        for message in messages {
            result.append(contentsOf: message.images)
            guard let interaction = message.toolInteraction else { continue }
            for (index, content) in interaction.result.content.enumerated() {
                guard case let .image(url) = content,
                      let attachment = AgentImageAttachment(
                        dataURLString: url.absoluteString,
                        id: "tool-\(interaction.invocation.id)-\(index)"
                      ) else {
                    continue
                }
                result.append(attachment)
            }
        }
        return result
    }

    private static func externalize(_ value: JSONValue) throws -> JSONValue {
        switch value {
        case let .array(values):
            return .array(try values.map(externalize))
        case let .object(original):
            var object = original
            var transformedKeys = Set<String>()
            if let imageURL = object["image_url"]?.stringValue,
               let attachment = AgentImageAttachment(dataURLString: imageURL) {
                object["image_url"] = .string(dataURLPrefix + digest(attachment.data))
                transformedKeys.insert("image_url")
            }
            if let base64 = object["b64_json"]?.stringValue,
               let attachment = AgentImageAttachment(base64String: base64) {
                object["b64_json"] = .string(base64Prefix + digest(attachment.data))
                transformedKeys.insert("b64_json")
            }
            if object["type"]?.stringValue == "image_generation_call",
               let base64 = object["result"]?.stringValue,
               let attachment = AgentImageAttachment(base64String: base64) {
                object["result"] = .string(base64Prefix + digest(attachment.data))
                transformedKeys.insert("result")
            }
            for (key, child) in object {
                guard !transformedKeys.contains(key) else {
                    continue
                }
                object[key] = try externalize(child)
            }
            return .object(object)
        case .bool, .null, .number, .string:
            return value
        }
    }

    private static func restore(
        _ value: JSONValue,
        using attachments: [String: AgentImageAttachment]
    ) throws -> JSONValue {
        switch value {
        case let .array(values):
            return .array(try values.map { try restore($0, using: attachments) })
        case let .object(original):
            var object = original
            for (key, child) in object {
                if let encoded = child.stringValue,
                   let replacement = try restoredString(encoded, using: attachments) {
                    object[key] = .string(replacement)
                } else {
                    object[key] = try restore(child, using: attachments)
                }
            }
            return .object(object)
        case .bool, .null, .number:
            return value
        case let .string(value):
            if let replacement = try restoredString(value, using: attachments) {
                return .string(replacement)
            }
            return .string(value)
        }
    }

    private static func restoredString(
        _ value: String,
        using attachments: [String: AgentImageAttachment]
    ) throws -> String? {
        guard let digestValue = referenceDigest(in: value) else { return nil }
        guard let attachment = attachments[digestValue] else {
            throw missingImage()
        }
        return value.hasPrefix(dataURLPrefix)
            ? attachment.dataURLString
            : attachment.data.base64EncodedString()
    }

    private static func collectReferenceDigests(in value: JSONValue, into digests: inout Set<String>) {
        switch value {
        case let .array(values):
            for child in values { collectReferenceDigests(in: child, into: &digests) }
        case let .object(object):
            for child in object.values { collectReferenceDigests(in: child, into: &digests) }
        case let .string(value):
            if let digest = referenceDigest(in: value) { digests.insert(digest) }
        case .bool, .null, .number:
            break
        }
    }

    private static func referenceDigest(in value: String) -> String? {
        for prefix in [dataURLPrefix, base64Prefix] where value.hasPrefix(prefix) {
            return String(value.dropFirst(prefix.count))
        }
        return nil
    }

    private static func missingImage() -> AgentRuntimeError {
        AgentRuntimeError(code: "responses_missing_persisted_image",
            message: "A persisted Responses image reference could not be resolved.")
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
