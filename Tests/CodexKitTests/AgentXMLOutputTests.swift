@testable import CodexKit
import XCTest

final class AgentXMLOutputTests: XCTestCase {
    let format = AgentXMLResponseFormat(name: "assessment", schema: .element("response", children: .sequence([
        .element("assessment", text: .string),
        .element("recommendation", text: .string, attributes: ["priority": .required(.string(enum: ["low", "medium", "high"]))]),
        .element("limitations", text: .string, occurs: .optional)
    ])))
    let source = "<response><assessment>café 😀 &amp; &lt;ok&gt;</assessment><recommendation priority=\"high\">Act</recommendation></response>"

    func testChosenSchemaAPIAndEveryByteBoundary() async throws {
        let bytes = Data(source.utf8)
        for split in 0 ... bytes.count {
            let decoder = try format.makeDecoder()
            let events = OutputEventRecorder<AgentXMLOutputEvent>()
            try await decoder.consume(Data(bytes.prefix(split)), into: events.sink)
            try await decoder.consume(Data(bytes.dropFirst(split)), into: events.sink)
            let document = try await decoder.finish(into: events.sink)
            XCTAssertEqual(document.rawXML, source)
            XCTAssertEqual(document.root.children.first?.text, "café 😀 & <ok>")
            XCTAssertEqual(document.root.children.last?.attributes["priority"], "high")
            XCTAssertEqual(document.root.children.count, 2)
        }
    }

    func testSubtreesAreProvisionalBeforeRootCloses() async throws {
        let decoder = try format.makeDecoder()
        let events = OutputEventRecorder<AgentXMLOutputEvent>()
        try await decoder.consume(Data("<response><assessment>First</assessment>".utf8), into: events.sink)
        let values = await events.values()
        XCTAssertTrue(values.contains { if case let .elementCompleted(element) = $0 { element.name == "assessment" } else { false } })
        do {
            try await decoder.consume(Data("<recommendation priority=\"INVALID\">Act</recommendation></response>".utf8), into: events.sink)
            _ = try await decoder.finish(into: events.sink)
            XCTFail("Invalid enum must prevent the final result")
        } catch {}
    }

    func testMixedContentNamespacedAttributesAndIdentity() async throws {
        let ns = "urn:test"
        let root = XMLName("response", namespaceURI: ns), item = XMLName("item", namespaceURI: ns)
        let format = AgentXMLResponseFormat(name: "mixed", schema: .element(root, children: .sequence([
            .element(item, mixed: .sequence([.element("em", text: .string, occurs: .optional)]),
                     attributes: ["id": .required(.string), XMLName("flag", namespaceURI: ns): .optional(.boolean)], occurs: .oneOrMore)
        ])), streaming: .init(identityAttribute: "id"))
        let source = "<r:response xmlns:r=\"urn:test\"><r:item id=\"same\" r:flag=\"true\">Hello <em>world</em>!</r:item><r:item id=\"same\"><![CDATA[second]]></r:item></r:response>"
        let decoder = try format.makeDecoder()
        for byte in source.utf8 { try await decoder.consume(Data([byte]), into: .init { _, _ in }) }
        let doc = try await decoder.finish(into: .init { _, _ in })
        XCTAssertEqual(doc.root.children[0].text, "Hello world!")
        XCTAssertEqual(doc.root.children[0].content.count, 3)
        XCTAssertEqual(doc.root.children.map(\.info.applicationID), ["same", "same"])
        XCTAssertNotEqual(doc.root.children[0].id, doc.root.children[1].id)
        XCTAssertEqual(doc.root.children[1].info.path.last?.index, 2)
        XCTAssertEqual(doc.root.children[0].attributes[XMLName("flag", namespaceURI: ns)], "true")
        XCTAssertEqual(try format.persistence?.decode(Data(source.utf8)).root, doc.root)
    }

    func testRequiredOrderUnknownAttributesAndMalformedEOFRejected() async throws {
        for source in ["<response/>", "<wrong/>",
                       "<response><recommendation priority=\"low\">a</recommendation><assessment>b</assessment></response>",
                       "<response><assessment extra=\"x\">a</assessment><recommendation priority=\"low\">b</recommendation></response>",
                       "<response><assessment>a</assessment>",
                       "<response><assessment>a</assessment><recommendation>b</recommendation></response>",
                       "<response/> trailing", "<?xml version=\"1.1\"?><response/>"] {
            do {
                let decoder = try format.makeDecoder()
                try await decoder.consume(Data(source.utf8), into: .init { _, _ in })
                _ = try await decoder.finish(into: .init { _, _ in })
                XCTFail("Invalid XML accepted: \(source)")
            } catch {}
        }
    }

    func testDTDExternalEntitiesAndExternalSchemasAreRejected() async throws {
        for source in ["<!DOCTYPE response SYSTEM 'file:///etc/passwd'><response/>",
                       "<!DOCTYPE response [<!ENTITY bomb 'boom'>]><response>&bomb;</response>",
                       "<!DOCTYPE response [<!ENTITY x SYSTEM 'https://example.com'>]><response>&x;</response>"] {
            let decoder = try format.makeDecoder()
            do { try await decoder.consume(Data(source.utf8), into: .init { _, _ in }); XCTFail("DTD accepted") } catch {}
        }
        for tag in ["include", "import", "redefine"] {
            let xsd = "<s:schema xmlns:s=\"http://www.w3.org/2001/XMLSchema\"><s:\(tag) schemaLocation=\"file:///etc/passwd\"/><s:element name=\"r\" type=\"s:string\"/></s:schema>"
            XCTAssertThrowsError(try AgentXMLResponseFormat(name: "bad", schema: .xsd(xsd, root: "r")).makeDecoder())
        }
    }

    func testEscapedAttributeValuesAndSourceSpellingArePreserved() async throws {
        let format = AgentXMLResponseFormat(name: "escaping", schema: .element("r", text: .string,
            attributes: ["a": .required(.string)]))
        let source = "\u{FEFF}<?xml version=\"1.0\" encoding=\"UTF-8\"?><!--comment--><r a=\"A &amp; B &quot;C&quot; &#xA; &lt;\"><![CDATA[raw <&>]]><?note ignored?></r>"
        let decoder = try format.makeDecoder()
        try await decoder.consume(Data(source.utf8), into: .init { _, _ in })
        let output = try await decoder.finish(into: .init { _, _ in })
        XCTAssertEqual(output.root.attributes["a"], "A & B \"C\" \n <")
        XCTAssertEqual(output.root.text, "raw <&>")
        XCTAssertEqual(output.rawXML, source)
    }

    func testInvalidSchemaAndNamespaceCollisionAreRejected() async throws {
        XCTAssertThrowsError(try AgentXMLResponseFormat(name: "enum", schema: .element("r", text: .string(enum: []))).makeDecoder())
        XCTAssertThrowsError(try AgentXMLResponseFormat(name: "bad", schema: .document(root: .element("r", occurs: .optional))).makeDecoder())
        let decoder = try AgentXMLResponseFormat(name: "r", schema: .element("r")).makeDecoder()
        do {
            try await decoder.consume(Data("<r xmlns:a=\"urn:x\" xmlns:b=\"urn:x\" a:v=\"1\" b:v=\"2\"/>".utf8), into: .init { _, _ in })
            XCTFail("Duplicate expanded attribute accepted")
        } catch {}
    }

    func testRawXSDReusableTypesAndDeterministicEmission() async throws {
        let schema = XMLSchema.document(root: .element("r", children: .choice([
            .element("n", content: .type("count")), .element("s", text: .string)
        ])), types: ["count": .simple(.restricted(.integer, facets: [.minInclusive("1"), .maxInclusive("3")]))])
        XCTAssertEqual(try schema.xsd(), try schema.xsd())
        let raw = AgentXMLResponseFormat(name: "raw", schema: .xsd(try schema.xsd(), root: "r"))
        let decoder = try raw.makeDecoder()
        try await decoder.consume(Data("<r><n>2</n></r>".utf8), into: .init { _, _ in })
        let result = try await decoder.finish(into: .init { _, _ in })
        XCTAssertEqual(result.root.text, "2")
        XCTAssertThrowsError(try AgentXMLResponseFormat(name: "wrong", schema: .xsd(schema.xsd(), root: "missing")).makeDecoder())
    }
}
