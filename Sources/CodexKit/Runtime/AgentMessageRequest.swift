import Foundation

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

struct CompiledRequestContext: Codable, Hashable, Sendable {
    var schemaName: String?
    var payload: JSONValue
}

struct CompiledRequestOptions: Codable, Hashable, Sendable {
    var schemaName: String?
    var mode: String
    var requirements: [String]
}
