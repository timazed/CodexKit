import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Preserve animation bytes in attachments; use a bounded first-frame preview
/// only in model requests. No preview replaces the original saved animation.
enum CodexGIFImage {
    static func isValidAnimation(_ data: Data) -> Bool {
        guard let source = source(data), CGImageSourceGetCount(source) >= 2,
              CGImageSourceGetCount(source) <= 16 else { return false }
        var pixels = 0
        for index in 0..<CGImageSourceGetCount(source) {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 32_000_000 / height else { return false }
            pixels += width * height
            guard pixels <= 32_000_000,
                  thumbnail(source, index: index, maximum: 1) != nil,
                  CGImageSourceGetStatusAtIndex(source, index) == .statusComplete else { return false }
        }
        return true
    }

    static func modelPreviews(_ items: [JSONValue]) -> [JSONValue] {
        items.map { item in
            guard var object = item.objectValue else { return item }
            let key: String
            switch object["type"]?.stringValue {
            case "message": key = "content"
            case "function_call_output", "custom_tool_call_output": key = "output"
            default: return item
            }
            guard let parts = object[key]?.arrayValue else { return item }
            object[key] = .array(parts.map { part in
                guard var image = part.objectValue, image["type"] == .string("input_image"),
                      let url = image["image_url"]?.stringValue, url.hasPrefix("data:image/gif;base64,"),
                      let attachment = AgentImageAttachment(dataURLString: url),
                      let source = source(attachment.data), let frame = thumbnail(source, index: 0, maximum: 2_048) else { return part }
                let output = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return part }
                CGImageDestinationAddImage(destination, frame, nil)
                guard CGImageDestinationFinalize(destination) else { return part }
                image["image_url"] = .string(AgentImageAttachment.png(output as Data).dataURLString)
                return .object(image)
            })
            return .object(object)
        }
    }

    private static func source(_ data: Data) -> CGImageSource? {
        guard let source = CGImageSourceCreateWithData(data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) == UTType.gif.identifier as CFString,
              CGImageSourceGetStatus(source) == .statusComplete else { return nil }
        return source
    }

    private static func thumbnail(_ source: CGImageSource, index: Int, maximum: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, index, [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maximum, kCGImageSourceShouldCache: false] as CFDictionary)
    }
}
