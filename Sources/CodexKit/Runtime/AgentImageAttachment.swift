import Foundation

public struct AgentImageGenerationMetadata: Codable, Hashable, Sendable {
    public let id: String
    public let status: String?
    public let action: String?
    public let revisedPrompt: String?
    public let background: String?
    public let outputFormat: String?
    public let quality: String?
    public let size: String?

    public init(
        id: String,
        status: String? = nil,
        action: String? = nil,
        revisedPrompt: String? = nil,
        background: String? = nil,
        outputFormat: String? = nil,
        quality: String? = nil,
        size: String? = nil
    ) {
        self.id = id
        self.status = status
        self.action = action
        self.revisedPrompt = revisedPrompt
        self.background = background
        self.outputFormat = outputFormat
        self.quality = quality
        self.size = size
    }
}

/// Requested input-image fidelity. Unsupported `original` detail is sent as `high`.
public enum AgentImageDetail: String, Codable, Hashable, Sendable {
    case auto, low, high, original
}

public struct AgentImageAttachment: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let mimeType: AgentImageMIMEType
    public let data: Data
    public let detail: AgentImageDetail?
    public let generationMetadata: AgentImageGenerationMetadata?

    public init(
        id: String = UUID().uuidString,
        mimeType: AgentImageMIMEType,
        data: Data,
        generationMetadata: AgentImageGenerationMetadata? = nil,
        detail: AgentImageDetail? = nil
    ) {
        self.id = id
        self.mimeType = mimeType
        self.data = data
        self.detail = detail
        self.generationMetadata = generationMetadata
    }

    public static func png(
        _ data: Data,
        id: String = UUID().uuidString,
        detail: AgentImageDetail?
    ) -> AgentImageAttachment {
        AgentImageAttachment(id: id, mimeType: .png, data: data, detail: detail)
    }

    public static func jpeg(
        _ data: Data,
        id: String = UUID().uuidString,
        detail: AgentImageDetail?
    ) -> AgentImageAttachment {
        AgentImageAttachment(id: id, mimeType: .jpeg, data: data, detail: detail)
    }

    public var dataURLString: String {
        "data:\(mimeType.rawValue);base64,\(data.base64EncodedString())"
    }

    public init?(
        dataURLString: String,
        id: String = UUID().uuidString,
        detail: AgentImageDetail?
    ) {
        let prefix = "data:"
        guard dataURLString.hasPrefix(prefix),
              dataURLString.utf8.count <= Self.maximumDataURLByteCount,
              let separatorIndex = dataURLString.range(of: ";base64,")
        else {
            return nil
        }

        let mimeTypeStart = dataURLString.index(dataURLString.startIndex, offsetBy: prefix.count)
        let mimeType = String(dataURLString[mimeTypeStart ..< separatorIndex.lowerBound])
        let base64Start = separatorIndex.upperBound
        let base64 = String(dataURLString[base64Start...])

        guard mimeType.utf8.count <= AgentStoreLimits.maximumIdentifierByteCount,
              let data = Self.decodeBoundedBase64(base64) else {
            return nil
        }
        self.init(id: id, mimeType: mimeType, data: data, detail: detail)
    }

    public init?(
        base64String: String,
        mimeType: AgentImageMIMEType,
        id: String = UUID().uuidString,
        generationMetadata: AgentImageGenerationMetadata? = nil,
        detail: AgentImageDetail? = nil
    ) {
        guard let data = Self.decodeBoundedBase64(base64String) else {
            return nil
        }

        self.init(id: id, mimeType: mimeType, data: data, generationMetadata: generationMetadata, detail: detail)
    }

    public init?(
        base64String: String,
        mimeType: String = "image/png",
        id: String = UUID().uuidString,
        generationMetadata: AgentImageGenerationMetadata? = nil,
        detail: AgentImageDetail?
    ) {
        self.init(base64String: base64String, mimeType: AgentImageMIMEType(rawValue: mimeType),
            id: id, generationMetadata: generationMetadata, detail: detail)
    }

    public init(id: String = UUID().uuidString, mimeType: String, data: Data,
        generationMetadata: AgentImageGenerationMetadata? = nil) {
        self.init(id: id, mimeType: mimeType, data: data, generationMetadata: generationMetadata, detail: nil)
    }

    public static func png(_ data: Data, id: String = UUID().uuidString) -> AgentImageAttachment {
        png(data, id: id, detail: nil)
    }

    public static func jpeg(_ data: Data, id: String = UUID().uuidString) -> AgentImageAttachment {
        jpeg(data, id: id, detail: nil)
    }

    public init?(dataURLString: String, id: String = UUID().uuidString) {
        self.init(dataURLString: dataURLString, id: id, detail: nil)
    }

    public init?(base64String: String, mimeType: String = "image/png", id: String = UUID().uuidString,
        generationMetadata: AgentImageGenerationMetadata? = nil) {
        self.init(base64String: base64String, mimeType: mimeType, id: id,
            generationMetadata: generationMetadata, detail: nil)
    }

    /// Compatibility for MIME strings supplied by existing integrations.
    public init(id: String = UUID().uuidString, mimeType: String, data: Data,
        generationMetadata: AgentImageGenerationMetadata? = nil, detail: AgentImageDetail?) {
        self.init(id: id, mimeType: AgentImageMIMEType(rawValue: mimeType), data: data,
            generationMetadata: generationMetadata, detail: detail)
    }

    var responsesInputImage: JSONValue {
        var image: [String: JSONValue] = [
            "type": .string("input_image"), "image_url": .string(dataURLString)
        ]
        if let detail { image["detail"] = .string(detail.rawValue) }
        return .object(image)
    }

    package static var maximumBase64ByteCount: Int {
        ((AgentStoreLimits.maximumImageByteCount + 2) / 3) * 4
    }

    package static var maximumDataURLByteCount: Int {
        maximumBase64ByteCount + AgentStoreLimits.maximumIdentifierByteCount + 16
    }

    private static func decodeBoundedBase64(_ value: String) -> Data? {
        guard !value.isEmpty,
              value.utf8.count <= maximumBase64ByteCount,
              let data = Data(base64Encoded: value),
              !data.isEmpty,
              data.count <= AgentStoreLimits.maximumImageByteCount else {
            return nil
        }
        return data
    }

}
