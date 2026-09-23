import Foundation
import libxml2

/// Per-decoder schema context. Only self-contained, preflighted documents reach XSD compilation.
final class AgentXMLSchemaValidator: @unchecked Sendable {
    private let schema: xmlSchemaPtr
    let rootName: XMLName

    init(xsd: String, root: XMLName, limits: AgentStructuredOutputLimits) throws {
        guard xsd.utf8.count <= limits.maximumSchemaBytes else { throw AgentOutputError.limit("XSD exceeds schema byte limit.") }
        try XMLSchemaCompiler.validName(root.localName)
        let preflight = try Self.parse(Data(xsd.utf8), limits: limits)
        let xs = "http://www.w3.org/2001/XMLSchema"
        guard preflight.name == XMLName("schema", namespaceURI: xs),
              preflight.attributes["targetNamespace"] == root.namespaceURI,
              preflight.children.contains(where: {
                  $0.name == XMLName("element", namespaceURI: xs) && $0.attributes["name"] == root.localName
              }) else { throw AgentOutputError.invalidFormat("XSD must declare the selected root and target namespace and use XSD 1.0.") }
        try Self.rejectExternalSchemaReferences(preflight)
        let data = Data(xsd.utf8)
        let doc = Self.readDocument(data)
        guard let doc else { throw AgentOutputError.invalidFormat("Could not read XSD document.") }
        defer { xmlFreeDoc(doc) }
        guard let context = xmlSchemaNewDocParserCtxt(doc) else { throw AgentOutputError.invalidFormat("Could not allocate XSD context.") }
        defer { xmlSchemaFreeParserCtxt(context) }
        xmlSchemaSetParserStructuredErrors(context, { _, _ in }, nil)
        guard let schema = xmlSchemaParse(context) else { throw AgentOutputError.invalidFormat("XSD compilation failed: unsupported or invalid schema.") }
        self.schema = schema; self.rootName = root
    }
    deinit { xmlSchemaFree(schema) }

    func validate(_ source: Data, root: AgentXMLElement) throws {
        guard root.name == rootName else { throw AgentOutputError.invalidOutput("XML root does not match the selected schema declaration.") }
        guard let doc = Self.readDocument(source) else { throw AgentOutputError.invalidOutput("Could not read the completed XML document.") }
        defer { xmlFreeDoc(doc) }
        guard let context = xmlSchemaNewValidCtxt(schema) else { throw AgentOutputError.invalidOutput("Could not allocate XSD validation context.") }
        defer { xmlSchemaFreeValidCtxt(context) }
        xmlSchemaSetValidStructuredErrors(context, { _, _ in }, nil)
        // No XML_SCHEMA_VAL_VC_I_CREATE: defaults must not alter the returned tree.
        guard xmlSchemaValidateDoc(context, doc) == 0 else { throw AgentOutputError.invalidOutput("XML document failed XSD validation.") }
    }

    static func parse(_ source: Data, limits: AgentStructuredOutputLimits) throws -> AgentXMLElement {
        guard source.count <= max(limits.maximumInputBytes, limits.maximumSchemaBytes),
              String(data: source, encoding: .utf8) != nil else { throw AgentOutputError.invalidOutput("XML must be bounded UTF-8.") }
        let parser = try AgentXMLParserEngine(limits: limits, options: .init(completedElements: .none, emitTextDeltas: false))
        for offset in stride(from: 0, to: source.count, by: 64) {
            _ = try parser.feed(Data(source[offset ..< min(offset + 64, source.count)]))
        }
        _ = try parser.feed(Data(), final: true)
        guard let root = parser.root else { throw AgentOutputError.invalidOutput("XML is missing its root.") }
        return root
    }
    private static func rejectExternalSchemaReferences(_ element: AgentXMLElement) throws {
        if element.attributes.contains(where: {
            $0.key.namespaceURI == "http://www.w3.org/2007/XMLSchema-versioning" && $0.key.localName == "minVersion" && $0.value != "1.0"
        }) { throw AgentOutputError.invalidFormat("XSD 1.1 version requirements are unsupported.") }
        if element.name.namespaceURI == "http://www.w3.org/2001/XMLSchema",
           ["include", "import", "redefine", "override", "assert", "alternative", "openContent", "defaultOpenContent"].contains(element.name.localName) {
            throw AgentOutputError.invalidFormat("External XSD references and XSD 1.1 constructs are unsupported.")
        }
        for child in element.children { try rejectExternalSchemaReferences(child) }
    }
    private static func readDocument(_ data: Data) -> xmlDocPtr? {
        data.withUnsafeBytes {
            xmlReadMemory($0.baseAddress?.assumingMemoryBound(to: CChar.self), Int32(data.count), nil, "UTF-8",
                          Int32(XML_PARSE_NONET.rawValue | XML_PARSE_NOERROR.rawValue | XML_PARSE_NOWARNING.rawValue))
        }
    }
}
