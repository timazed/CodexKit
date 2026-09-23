import Foundation

public struct AgentXMLPathComponent: Codable, Hashable, Sendable {
    public let name: XMLName
    /// One-based index among siblings with the same expanded name.
    public let index: Int
}

public struct AgentXMLElementInfo: Codable, Hashable, Sendable {
    /// Decoder-assigned identity, independent of potentially duplicated application IDs.
    public let id: UInt64
    public let name: XMLName
    public let qualifiedName: String
    public let path: [AgentXMLPathComponent]
    public let attributes: [XMLName: String]
    public let namespaceDeclarations: [String: String]
    public let applicationID: String?
    public var indexedPath: String {
        path.enumerated().map { offset, part in
            "/" + part.name.expandedName + (offset == 0 ? "" : "[\(part.index)]")
        }.joined()
    }
}

public indirect enum AgentXMLContent: Codable, Hashable, Sendable {
    case text(String)
    case element(AgentXMLElement)
}

public struct AgentXMLElement: Codable, Hashable, Sendable, Identifiable {
    public let info: AgentXMLElementInfo
    public let content: [AgentXMLContent]
    public var id: UInt64 { info.id }
    public var name: XMLName { info.name }
    public var attributes: [XMLName: String] { info.attributes }
    public var children: [AgentXMLElement] { content.compactMap { if case let .element(value) = $0 { value } else { nil } } }
    /// All descendant text in document order; scalar values remain lexical XML text.
    public var text: String { content.map { switch $0 { case let .text(value): value; case let .element(value): value.text } }.joined() }
}

public struct AgentXMLDocument: Codable, Hashable, Sendable {
    public let rawXML: String
    public let root: AgentXMLElement
}

public enum AgentXMLOutputEvent: Sendable {
    case documentStarted
    case elementStarted(AgentXMLElementInfo)
    case textDelta(elementID: UInt64, text: String)
    case elementEnded(AgentXMLElementInfo)
    /// A complete subtree, still provisional until the enclosing outputCommitted event.
    case elementCompleted(AgentXMLElement)
}

public enum AgentXMLStreamingSelection: Sendable {
    case none, directChildren, all
    /// Expanded-name paths, without sibling indexes. Prefix aliases are equivalent.
    case paths(Set<[XMLName]>)
    func includes(_ path: [AgentXMLPathComponent]) -> Bool {
        switch self {
        case .none: false
        case .directChildren: path.count == 2
        case .all: true
        case let .paths(paths): paths.contains(path.map(\.name))
        }
    }
}

public struct AgentXMLStreamingOptions: Sendable {
    public var completedElements: AgentXMLStreamingSelection
    public var emitTextDeltas: Bool
    public var identityAttribute: XMLName?
    public init(completedElements: AgentXMLStreamingSelection = .directChildren,
                emitTextDeltas: Bool = true, identityAttribute: XMLName? = nil) {
        self.completedElements = completedElements; self.emitTextDeltas = emitTextDeltas
        self.identityAttribute = identityAttribute
    }
}
