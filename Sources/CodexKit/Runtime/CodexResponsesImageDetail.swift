import Foundation


enum CodexResponsesImageDetail {
    /// Normalize only protocol image content, never arbitrary JSON in tool results.
    /// The caller retains the unmodified history for persistence and future model switches.
    static func normalize(_ items: [JSONValue], supportsOriginal: Bool) -> [JSONValue] {
        guard !supportsOriginal else { return items }
        return items.map { item in
            guard var object = item.objectValue else { return item }
            let key: String
            switch object["type"]?.stringValue {
            case "message": key = "content"
            case "function_call_output", "custom_tool_call_output": key = "output"
            default: return item
            }
            guard let content = object[key]?.arrayValue else { return item }
            object[key] = .array(content.map { value in
                guard var image = value.objectValue, image["type"] == .string("input_image"),
                      image["detail"] == .string("original") else { return value }
                image["detail"] = .string("high")
                return .object(image)
            })
            return .object(object)
        }
    }
}
