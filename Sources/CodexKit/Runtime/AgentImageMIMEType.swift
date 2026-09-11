import Foundation

/// An extensible image media type. Codable preserves the existing MIME string representation.
public struct AgentImageMIMEType: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }

    public static let png = Self(rawValue: "image/png")
    public static let jpeg = Self(rawValue: "image/jpeg")
    public static let gif = Self(rawValue: "image/gif")
    public static let webp = Self(rawValue: "image/webp")
    public static let heic = Self(rawValue: "image/heic")
    public static let heif = Self(rawValue: "image/heif")

    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    init?(pathExtension: String) {
        switch pathExtension.lowercased() {
        case "png": self = .png
        case "jpg", "jpeg": self = .jpeg
        case "gif": self = .gif
        case "webp": self = .webp
        case "heic": self = .heic
        case "heif": self = .heif
        default: return nil
        }
    }

}
