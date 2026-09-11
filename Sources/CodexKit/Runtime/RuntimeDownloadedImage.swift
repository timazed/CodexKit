import Foundation
import ImageIO
import UniformTypeIdentifiers

enum RuntimeDownloadedImage {
    /// Inspect and decode a tiny thumbnail without changing the stored bytes.
    static func mimeType(for data: Data) -> AgentImageMIMEType? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, options),
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetCount(source) > 0,
              let identifier = CGImageSourceGetType(source),
              let rawMIMEType = UTType(identifier as String)?.preferredMIMEType
        else { return nil }
        let mimeType = AgentImageMIMEType(rawValue: rawMIMEType)
        switch mimeType {
        case .png, .jpeg, .gif, .webp, .heic, .heif: break
        default: return nil
        }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 1,
            kCGImageSourceShouldCache: false,
        ] as CFDictionary
        guard CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) != nil,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { return nil }
        return mimeType
    }
}
