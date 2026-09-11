import Foundation


enum CodexResponsesImageDetail {
    /// Normalize only protocol image content, never arbitrary JSON in tool results.
    /// The caller retains the unmodified history for persistence and future model switches.
    static func normalize(_ items: [JSONValue], supportsOriginal: Bool) -> [JSONValue] {
        guard !supportsOriginal else { return items }
        return items.map { item in
            guard var object = item.objectValue else { return item }
            let key: String
            switch ResponsesItemType(wireValue: object["type"]) {
            case .message: key = "content"
            case .functionCallOutput, .customToolCallOutput: key = "output"
            default: return item
            }
            guard let content = object[key]?.arrayValue else { return item }
            object[key] = .array(content.map { value in
                guard var image = value.objectValue, image["type"] == ResponsesContentType.inputImage.jsonValue,
                      image["detail"] == .string(AgentImageDetail.original.rawValue) else { return value }
                image["detail"] = .string(AgentImageDetail.high.rawValue)
                return .object(image)
            })
            return .object(object)
        }
    }
}
