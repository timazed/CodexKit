import Foundation
import libxml2

/// Deterministic, bounded XSD emission. libxml2 checks type/facet/UPA constraints afterward.
struct XMLSchemaCompiler {
    let namespace: String?
    var nodes = 0
    static func compile(_ schema: XMLSchema) throws -> String {
        switch schema {
        case let .xsd(source, _): return source
        case let .document(root, types):
            guard root.occurs == .once, types.count <= 1_000 else {
                throw AgentOutputError.invalidFormat("Invalid root occurrence or type count.")
            }
            var compiler = Self(namespace: root.name.namespaceURI)
            var result =
                "<xs:schema xmlns:xs=\"http://www.w3.org/2001/XMLSchema\" elementFormDefault=\"unqualified\" attributeFormDefault=\"unqualified\""
            if let ns = root.name.namespaceURI {
                result += " targetNamespace=\"\(escape(ns))\" xmlns:t=\"\(escape(ns))\""
            }
            result += ">"
            for name in types.keys.sorted() {
                try validName(name)
                switch types[name]! {
                case let .simple(type): result += try compiler.simple(type, name: name, depth: 0)
                case let .complex(content, attributes):
                    result += try compiler.complex(content, attributes: attributes, name: name, depth: 0)
                }
            }
            result += try compiler.element(root, global: true, depth: 0)
            result += "</xs:schema>"
            guard result.utf8.count <= 1_048_576 else { throw AgentOutputError.limit("Generated XSD exceeds limit.") }
            return result
        }
    }

    mutating func budget(_ depth: Int) throws {
        nodes += 1
        guard depth <= 64, nodes <= 10_000 else { throw AgentOutputError.limit("XML schema complexity exceeds limit.") }
    }
    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "\r", with: "&#13;").replacingOccurrences(of: "\n", with: "&#10;")
            .replacingOccurrences(of: "\t", with: "&#9;")
    }
    static func validName(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 1_024, !value.utf8.contains(0),
            value.utf8CString.withUnsafeBytes({
                xmlValidateNCName($0.baseAddress?.assumingMemoryBound(to: xmlChar.self), 0)
            }) == 0
        else {
            throw AgentOutputError.invalidFormat("Invalid XML name.")
        }
    }
    func qualified(_ name: String) throws -> String {
        try Self.validName(name)
        return namespace == nil ? name : "t:" + name
    }
    func form(_ name: XMLName) throws -> String {
        try Self.validName(name.localName)
        guard name.namespaceURI == nil || name.namespaceURI == namespace else {
            throw AgentOutputError.invalidFormat(
                "The Swift XML schema supports one target namespace; use self-contained XSD for other constructs.")
        }
        return name.namespaceURI == nil ? "unqualified" : "qualified"
    }
    func occurrence(_ value: XMLOccurrence) throws -> String {
        let bounds: (Int, Int?)
        switch value {
        case .once: return ""
        case .optional: bounds = (0, 1)
        case .zeroOrMore: bounds = (0, nil)
        case .oneOrMore: bounds = (1, nil)
        case let .range(min, max): bounds = (min, max)
        }
        guard bounds.0 >= 0, bounds.1.map({ $0 >= bounds.0 }) ?? true else {
            throw AgentOutputError.invalidFormat("Invalid XML occurrence bounds.")
        }
        return " minOccurs=\"\(bounds.0)\" maxOccurs=\"\(bounds.1.map(String.init) ?? "unbounded")\""
    }
    mutating func element(_ value: XMLElementDeclaration, global: Bool, depth: Int) throws -> String {
        try budget(depth)
        let form = try form(value.name)
        var start = "<xs:element name=\"\(value.name.localName)\""
        if !global { start += " form=\"\(form)\"" + (try occurrence(value.occurs)) }
        if case let .type(name) = value.content {
            guard value.attributes.isEmpty else {
                throw AgentOutputError.invalidFormat("Type references cannot add inline attributes.")
            }
            start += " type=\"\(try qualified(name))\""
        }
        start += ">"
        if let description = value.description {
            start += "<xs:annotation><xs:documentation>\(Self.escape(description))</xs:documentation></xs:annotation>"
        }
        switch value.content {
        case .type: break
        case let .text(type) where value.attributes.isEmpty: start += try simple(type, depth: depth + 1)
        default: start += try complex(value.content, attributes: value.attributes, depth: depth + 1)
        }
        return start + "</xs:element>"
    }
    mutating func model(_ value: XMLContentModel, depth: Int) throws -> String {
        try budget(depth)
        let tag: String, elements: [XMLParticle], occurs: XMLOccurrence
        switch value {
        case let .sequence(children, count):
            tag = "sequence"
            elements = children
            occurs = count
        case let .choice(children, count):
            tag = "choice"
            elements = children
            occurs = count
        case let .all(children, count):
            tag = "all"
            elements = children
            occurs = count
        }
        var result = "<xs:\(tag)\(try occurrence(occurs))>"
        for child in elements {
            switch child {
            case let .element(value): result += try element(value, global: false, depth: depth + 1)
            case let .group(value): result += try model(value, depth: depth + 1)
            }
        }
        return result + "</xs:\(tag)>"
    }
    mutating func attributes(_ values: [XMLName: XMLAttribute], depth: Int) throws -> String {
        var result = ""
        for name in values.keys.sorted(by: { $0.expandedName < $1.expandedName }) {
            try budget(depth)
            let type: XMLSimpleType, use: String
            switch values[name]! {
            case let .required(value):
                type = value
                use = "required"
            case let .optional(value):
                type = value
                use = "optional"
            }
            result += "<xs:attribute name=\"\(name.localName)\" form=\"\(try form(name))\" use=\"\(use)\">"
            result += try simple(type, depth: depth + 1)
            result += "</xs:attribute>"
        }
        return result
    }
    mutating func complex(
        _ content: XMLContent, attributes values: [XMLName: XMLAttribute],
        name: String? = nil, depth: Int
    ) throws -> String {
        try budget(depth)
        var result = "<xs:complexType" + (name.map { " name=\"\($0)\"" } ?? "")
        if case .mixed = content { result += " mixed=\"true\"" }
        result += ">"
        let attrs = try attributes(values, depth: depth + 1)
        switch content {
        case let .text(type):
            let (base, facets) = try restriction(type, depth: depth + 1)
            // XSD simpleContent extension needs a named base. A restriction of an
            // inline simple type is legal using xs:anyType as the complex base.
            if facets.isEmpty {
                result += "<xs:simpleContent><xs:extension base=\"\(base)\">\(attrs)</xs:extension></xs:simpleContent>"
            } else {
                result += "<xs:simpleContent><xs:restriction base=\"xs:anyType\">"
                result += "<xs:simpleType><xs:restriction base=\"\(base)\">\(facets)</xs:restriction></xs:simpleType>"
                result += attrs + "</xs:restriction></xs:simpleContent>"
            }
        case let .children(children), let .mixed(children): result += try model(children, depth: depth + 1) + attrs
        case .empty: result += attrs
        case let .type(base):
            result +=
                "<xs:complexContent><xs:extension base=\"\(try qualified(base))\">\(attrs)</xs:extension></xs:complexContent>"
        }
        return result + "</xs:complexType>"
    }
    mutating func simple(_ type: XMLSimpleType, name: String? = nil, depth: Int) throws -> String {
        let (base, facets) = try restriction(type, depth: depth)
        return "<xs:simpleType" + (name.map { " name=\"\($0)\"" } ?? "")
            + "><xs:restriction base=\"\(base)\">\(facets)</xs:restriction></xs:simpleType>"
    }
    mutating func restriction(_ type: XMLSimpleType, depth: Int) throws -> (String, String) {
        try budget(depth)
        switch type {
        case let .stringValues(values):
            if let values, values.isEmpty {
                throw AgentOutputError.invalidFormat("XML enumeration must contain at least one value.")
            }
            return ("xs:string", try (values ?? []).map { try facet(.enumeration($0)) }.joined())
        case .integer: return ("xs:integer", "")
        case .decimal: return ("xs:decimal", "")
        case .boolean: return ("xs:boolean", "")
        case .date: return ("xs:date", "")
        case .dateTime: return ("xs:dateTime", "")
        case let .named(name): return (try qualified(name), "")
        case let .restricted(base, facets):
            let (type, existing) = try restriction(base, depth: depth + 1)
            return (type, existing + (try facets.map { try facet($0) }.joined()))
        }
    }
    mutating func facet(_ facet: XMLFacet) throws -> String {
        try budget(0)
        let name: String, value: String
        switch facet {
        case let .minLength(v):
            name = "minLength"
            value = String(v)
        case let .maxLength(v):
            name = "maxLength"
            value = String(v)
        case let .length(v):
            name = "length"
            value = String(v)
        case let .minInclusive(v):
            name = "minInclusive"
            value = v
        case let .maxInclusive(v):
            name = "maxInclusive"
            value = v
        case let .minExclusive(v):
            name = "minExclusive"
            value = v
        case let .maxExclusive(v):
            name = "maxExclusive"
            value = v
        case let .enumeration(v):
            name = "enumeration"
            value = v
        }
        guard value.utf8.count <= 65_536 else { throw AgentOutputError.limit("XML facet exceeds limit.") }
        return "<xs:\(name) value=\"\(Self.escape(value))\"/>"
    }
}
