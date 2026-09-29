import Foundation
import ImageIO

/// Pixel dimensions read from the returned image bytes, independent of provider metadata.
public struct AgentImageDimensions: Codable, Hashable, Sendable, CustomStringConvertible {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public var description: String { "\(width)x\(height)" }

    static func inspect(_ data: Data) -> Self? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              CGImageSourceGetStatus(source) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        // Validate the compressed image without allocating a full-resolution bitmap.
        let thumbnailOptions = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 1, kCGImageSourceShouldCache: false] as CFDictionary
        guard CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) != nil,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { return nil }
        return .init(width: width, height: height)
    }

}

extension AgentGeneratedImage {
    /// Actual output dimensions, read from the returned bytes. This never requests or changes a size.
    public var pixelSize: AgentImageDimensions? { image.pixelSize }
}

extension AgentImageAttachment {
    /// Actual dimensions for an attachment, including images returned in a chat transcript.
    public var pixelSize: AgentImageDimensions? { AgentImageDimensions.inspect(data) }
}
