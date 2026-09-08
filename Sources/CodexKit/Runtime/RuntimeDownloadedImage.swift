import Foundation
import ImageIO
import UniformTypeIdentifiers

enum RuntimeDownloadedImage {
    /// Inspect and decode a tiny thumbnail without changing the stored bytes.
    static func mimeType(for data: Data) -> String? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, options),
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetCount(source) > 0,
              let identifier = CGImageSourceGetType(source),
              let mimeType = UTType(identifier as String)?.preferredMIMEType,
              ["image/png", "image/jpeg", "image/gif", "image/webp", "image/heic", "image/heif"].contains(mimeType)
        else { return nil }
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
