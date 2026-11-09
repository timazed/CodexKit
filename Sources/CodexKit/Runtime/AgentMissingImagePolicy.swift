import Foundation

public enum AgentMissingImagePolicy: String, Codable, Hashable, Sendable {
    /// Keep strict unresolved-reference errors (the compatibility default).
    case fail
    /// Replace unresolved image content in outbound requests with explicit text.
    /// Storage/access failures still propagate before request preparation.
    case placeholder
}

extension CodexResponsesImageReferences {
    static func replacingUnavailableImages(_ value: JSONValue, missing: Set<String>) -> JSONValue {
        switch value {
        case let .object(object):
            let type = object["type"]?.stringValue
            func isMissing(_ field: String) -> Bool {
                guard let encoded = object[field]?.stringValue,
                      let digest = referenceDigest(in: encoded) else { return false }
                return missing.contains(digest)
            }
            if (type == "input_image" || type == "output_image"), isMissing("image_url") {
                return .object(["type": .string(type == "input_image" ? "input_text" : "output_text"),
                    "text": .string("[image unavailable]")])
            }
            if type == "image_generation_call", isMissing("result") {
                return .object(["type": .string("message"), "role": .string("assistant"),
                    "content": .array([.object(["type": .string("output_text"),
                        "text": .string("[image unavailable]")])])])
            }
            return .object(object.mapValues { replacingUnavailableImages($0, missing: missing) })
        case let .array(values):
            return .array(values.map { replacingUnavailableImages($0, missing: missing) })
        case .null, .bool, .number, .string: return value
        }
    }
}
