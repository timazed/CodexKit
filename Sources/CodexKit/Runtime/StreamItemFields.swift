import Foundation

/// Projects the already decoded wire object into typed fields, preserving the
/// required/optional field validation of the original Decodable models.
struct StreamItemFields {
    let object: [String: JSONValue]
    let codingPath: [any CodingKey]

    func kind(for type: ResponsesItemType?) throws -> StreamItemKind {
        switch type {
        case .message:
            return .message(try .init(id: optionalString("id"), role: string("role"),
                phase: optionalString("phase").map(AgentMessagePhase.init(rawValue:)), content: content()))
        case .functionCall:
            return .functionCall(try .init(name: string("name"), arguments: string("arguments"),
                callID: string("call_id")))
        case .imageGenerationCall:
            return .imageGenerationCall(try .init(id: string("id"), status: string("status"),
                action: optionalString("action"), background: optionalString("background"),
                outputFormat: optionalString("output_format"), quality: optionalString("quality"),
                size: optionalString("size"), revisedPrompt: optionalString("revised_prompt"),
                result: optionalString("result")))
        case .webSearchCall:
            return .webSearchCall(try .init(id: optionalString("id"),
                status: optionalString("status").map(AgentWebSearchStatus.init(rawValue:)),
                action: object["action"] == .null ? nil : object["action"]))
        default:
            return .other
        }
    }

    private func required(_ key: String, type: Any.Type) throws -> JSONValue {
        guard let value = object[key] else {
            throw DecodingError.keyNotFound(Key(key), .init(codingPath: codingPath,
                debugDescription: "Missing required field \(key)."))
        }
        guard value != .null else {
            throw DecodingError.valueNotFound(type, context(key))
        }
        return value
    }

    private func string(_ key: String) throws -> String {
        guard let value = try required(key, type: String.self).stringValue else {
            throw DecodingError.typeMismatch(String.self, context(key))
        }
        return value
    }

    private func optionalString(_ key: String) throws -> String? {
        guard let value = object[key], value != .null else { return nil }
        guard let text = value.stringValue else {
            throw DecodingError.typeMismatch(String.self, context(key))
        }
        return text
    }

    private func content() throws -> [StreamMessageContent] {
        guard let values = try required("content", type: [StreamMessageContent].self).arrayValue else {
            throw DecodingError.typeMismatch([StreamMessageContent].self, context("content"))
        }
        return try values.enumerated().map { index, value in
            let path = codingPath + [Key("content"), Key(index: index)]
            guard let object = value.objectValue else {
                let context = DecodingError.Context(codingPath: path, debugDescription: "Expected content object.")
                if value == .null { throw DecodingError.valueNotFound([String: JSONValue].self, context) }
                throw DecodingError.typeMismatch([String: JSONValue].self, context)
            }
            return StreamMessageContent(object: object)
        }
    }

    private func context(_ key: String) -> DecodingError.Context {
        .init(codingPath: codingPath + [Key(key)], debugDescription: "Invalid field \(key).")
    }

    private struct Key: CodingKey {
        let stringValue: String
        let intValue: Int?
        init(_ value: String) { stringValue = value; intValue = nil }
        init(index: Int) { stringValue = "Index \(index)"; intValue = index }
        init?(stringValue: String) { self.init(stringValue) }
        init?(intValue: Int) { self.init(index: intValue) }
    }
}
