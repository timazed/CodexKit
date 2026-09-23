import Foundation

/// Expanded XML name. Prefix spelling is not part of name equality.
public struct XMLName: Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let localName: String
    public let namespaceURI: String?
    public init(_ localName: String, namespaceURI: String? = nil) {
        self.localName = localName
        self.namespaceURI = namespaceURI?.isEmpty == false ? namespaceURI : nil
    }
    public init(stringLiteral value: String) { self.init(value) }
    public var expandedName: String { namespaceURI.map { "{\($0)}\(localName)" } ?? localName }
}

public enum XMLOccurrence: Hashable, Sendable {
    case once, optional, zeroOrMore, oneOrMore
    case range(min: Int, max: Int?)
}

public indirect enum XMLSimpleType: Hashable, Sendable {
    case stringValues([String]?)
    case integer, decimal, boolean, date, dateTime
    case named(String)
    case restricted(XMLSimpleType, facets: [XMLFacet])
    public static var string: Self { .stringValues(nil) }
    public static func string(enum values: [String]) -> Self { .stringValues(values) }
}

/// Facets use XSD lexical values and XSD semantics, not Foundation regular expressions.
public enum XMLFacet: Hashable, Sendable {
    case minLength(Int), maxLength(Int), length(Int)
    case minInclusive(String), maxInclusive(String), minExclusive(String), maxExclusive(String)
    case enumeration(String)
}

public enum XMLAttribute: Hashable, Sendable {
    case required(XMLSimpleType), optional(XMLSimpleType)
}

public indirect enum XMLContent: Hashable, Sendable {
    case empty
    case text(XMLSimpleType)
    case children(XMLContentModel)
    case mixed(XMLContentModel)
    case type(String)
}

public indirect enum XMLContentModel: Hashable, Sendable {
    case sequence([XMLParticle], occurs: XMLOccurrence = .once)
    case choice([XMLParticle], occurs: XMLOccurrence = .once)
    case all([XMLParticle], occurs: XMLOccurrence = .once)
}

public struct XMLElementDeclaration: Hashable, Sendable {
    public let name: XMLName
    public let content: XMLContent
    public let attributes: [XMLName: XMLAttribute]
    public let occurs: XMLOccurrence
    public let description: String?

    public static func element(
        _ name: XMLName, text: XMLSimpleType,
        attributes: [XMLName: XMLAttribute] = [:], occurs: XMLOccurrence = .once,
        description: String? = nil
    ) -> Self {
        .init(name: name, content: .text(text), attributes: attributes, occurs: occurs, description: description)
    }
    public static func element(
        _ name: XMLName, children: XMLContentModel,
        attributes: [XMLName: XMLAttribute] = [:], occurs: XMLOccurrence = .once,
        description: String? = nil
    ) -> Self {
        .init(
            name: name, content: .children(children), attributes: attributes, occurs: occurs, description: description)
    }
    public static func element(
        _ name: XMLName, mixed: XMLContentModel,
        attributes: [XMLName: XMLAttribute] = [:], occurs: XMLOccurrence = .once,
        description: String? = nil
    ) -> Self {
        .init(name: name, content: .mixed(mixed), attributes: attributes, occurs: occurs, description: description)
    }
    public static func element(
        _ name: XMLName, content: XMLContent = .empty,
        attributes: [XMLName: XMLAttribute] = [:], occurs: XMLOccurrence = .once,
        description: String? = nil
    ) -> Self {
        .init(name: name, content: content, attributes: attributes, occurs: occurs, description: description)
    }
}

public indirect enum XMLParticle: Hashable, Sendable {
    case element(XMLElementDeclaration)
    case group(XMLContentModel)
    public static func element(
        _ name: XMLName, text: XMLSimpleType,
        attributes: [XMLName: XMLAttribute] = [:], occurs: XMLOccurrence = .once,
        description: String? = nil
    ) -> Self {
        .element(.element(name, text: text, attributes: attributes, occurs: occurs, description: description))
    }
    public static func element(
        _ name: XMLName, children: XMLContentModel,
        attributes: [XMLName: XMLAttribute] = [:], occurs: XMLOccurrence = .once,
        description: String? = nil
    ) -> Self {
        .element(.element(name, children: children, attributes: attributes, occurs: occurs, description: description))
    }
    public static func element(
        _ name: XMLName, mixed: XMLContentModel,
        attributes: [XMLName: XMLAttribute] = [:], occurs: XMLOccurrence = .once,
        description: String? = nil
    ) -> Self {
        .element(.element(name, mixed: mixed, attributes: attributes, occurs: occurs, description: description))
    }
    public static func element(
        _ name: XMLName, content: XMLContent = .empty,
        attributes: [XMLName: XMLAttribute] = [:], occurs: XMLOccurrence = .once,
        description: String? = nil
    ) -> Self {
        .element(.element(name, content: content, attributes: attributes, occurs: occurs, description: description))
    }
}

public enum XMLTypeDefinition: Hashable, Sendable {
    case simple(XMLSimpleType)
    case complex(XMLContent, attributes: [XMLName: XMLAttribute] = [:])
}

/// The Swift DSL and self-contained XSD share one authoritative XSD 1.0 validator.
public enum XMLSchema: Hashable, Sendable {
    case document(root: XMLElementDeclaration, types: [String: XMLTypeDefinition] = [:])
    case xsd(String, root: XMLName)

    public static func element(
        _ name: XMLName, text: XMLSimpleType,
        attributes: [XMLName: XMLAttribute] = [:]
    ) -> Self {
        .document(root: .element(name, text: text, attributes: attributes))
    }
    public static func element(
        _ name: XMLName, children: XMLContentModel,
        attributes: [XMLName: XMLAttribute] = [:]
    ) -> Self {
        .document(root: .element(name, children: children, attributes: attributes))
    }
    public static func element(
        _ name: XMLName, mixed: XMLContentModel,
        attributes: [XMLName: XMLAttribute] = [:]
    ) -> Self {
        .document(root: .element(name, mixed: mixed, attributes: attributes))
    }
    public static func element(
        _ name: XMLName, content: XMLContent = .empty,
        attributes: [XMLName: XMLAttribute] = [:]
    ) -> Self {
        .document(root: .element(name, content: content, attributes: attributes))
    }
    public var rootName: XMLName {
        switch self {
        case let .document(root, _): root.name
        case let .xsd(_, root): root
        }
    }
    public func xsd() throws -> String { try XMLSchemaCompiler.compile(self) }
}
