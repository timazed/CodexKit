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

public struct AgentImageAttachment: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let mimeType: String
    public let data: Data
    public let generationMetadata: AgentImageGenerationMetadata?

    public init(
        id: String = UUID().uuidString,
        mimeType: String,
        data: Data,
        generationMetadata: AgentImageGenerationMetadata? = nil
    ) {
        self.id = id
        self.mimeType = mimeType
        self.data = data
        self.generationMetadata = generationMetadata
    }

    public static func png(
        _ data: Data,
        id: String = UUID().uuidString
    ) -> AgentImageAttachment {
        AgentImageAttachment(id: id, mimeType: "image/png", data: data)
    }

    public static func jpeg(
        _ data: Data,
        id: String = UUID().uuidString
    ) -> AgentImageAttachment {
        AgentImageAttachment(id: id, mimeType: "image/jpeg", data: data)
    }

    public var dataURLString: String {
        "data:\(mimeType);base64,\(data.base64EncodedString())"
    }

    public init?(
        dataURLString: String,
        id: String = UUID().uuidString
    ) {
        let prefix = "data:"
        guard dataURLString.hasPrefix(prefix),
              let separatorIndex = dataURLString.range(of: ";base64,")
        else {
            return nil
        }

        let mimeTypeStart = dataURLString.index(dataURLString.startIndex, offsetBy: prefix.count)
        let mimeType = String(dataURLString[mimeTypeStart ..< separatorIndex.lowerBound])
        let base64Start = separatorIndex.upperBound
        let base64 = String(dataURLString[base64Start...])

        self.init(id: id, mimeType: mimeType, data: Data(base64Encoded: base64) ?? Data())
        if data.isEmpty {
            return nil
        }
    }

    public init?(
        base64String: String,
        mimeType: String = "image/png",
        id: String = UUID().uuidString,
        generationMetadata: AgentImageGenerationMetadata? = nil
    ) {
        guard let data = Data(base64Encoded: base64String), !data.isEmpty else {
            return nil
        }

        self.init(id: id, mimeType: mimeType, data: data, generationMetadata: generationMetadata)
    }
}
