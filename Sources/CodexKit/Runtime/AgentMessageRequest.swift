import Foundation

public struct RequestContext: Codable, Hashable, Sendable {
    public var schemaName: String?
    public var payload: JSONValue

    public init(
        schemaName: String? = nil,
        payload: JSONValue
    ) {
        self.schemaName = schemaName
        self.payload = payload
    }

    public init<Payload: Encodable & Sendable>(
        _ payload: Payload,
        schemaName: String? = nil,
        encoder: JSONEncoder = JSONEncoder()
    ) throws {
        self.schemaName = schemaName
        self.payload = try JSONValue.encoding(payload, encoder: encoder)
    }
}

public protocol NaturalLanguageRenderable {
    var naturalLanguage: String { get }
}

public protocol RequestMode: NaturalLanguageRenderable, Sendable { }
public protocol RequestRequirement: NaturalLanguageRenderable, Sendable { }

public protocol RequestOptionsRepresentable: Sendable {
    associatedtype ModeType: RequestMode
    associatedtype RequirementType: RequestRequirement

    static var schemaName: String? { get }
    var mode: ModeType { get }
    var requirements: [RequirementType] { get }
}

extension RequestOptionsRepresentable {
    public static var schemaName: String? {
        String(describing: Self.self)
    }
}

public struct RequestOptions: Codable, Hashable, Sendable {
    public var schemaName: String?
    public var mode: String
    public var requirements: [String]

    public init(
        schemaName: String? = nil,
        mode: String,
        requirements: [String] = []
    ) {
        self.schemaName = schemaName
        self.mode = mode
        self.requirements = requirements
    }
}
