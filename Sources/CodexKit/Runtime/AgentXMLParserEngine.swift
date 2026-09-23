import Foundation
import libxml2

/// Single-owner synchronous push parser. Its owning decoder actor serializes all access.
/// No global parser, error handler, or entity loader is changed.
final class AgentXMLParserEngine: @unchecked Sendable {
    struct Frame {
        let info: AgentXMLElementInfo
        var content: [AgentXMLContent] = []
        var siblings: [XMLName: Int] = [:]
    }
    let limits: AgentStructuredOutputLimits
    let options: AgentXMLStreamingOptions
    var parser: xmlParserCtxtPtr?
    var stack: [Frame] = []
    var root: AgentXMLElement?
    var error: AgentOutputError?
    var events: [(AgentXMLOutputEvent, Int)] = []
    var eventBytes = 0
    var nodeCount: UInt64 = 0
    var retainedBytes = 0
    var finished = false

    init(limits: AgentStructuredOutputLimits, options: AgentXMLStreamingOptions) throws {
        self.limits = limits
        self.options = options
        var sax = xmlSAXHandler()
        sax.initialized = UInt32(XML_SAX2_MAGIC)
        sax.startDocument = { ctx in engine(ctx)?.emit(.documentStarted, size: 0) }
        sax.startElementNs = { ctx, local, prefix, uri, count, namespaces, attrCount, _, attributes in
            engine(ctx)?.start(
                local: local, prefix: prefix, uri: uri, namespaceCount: count,
                namespaces: namespaces, attributeCount: attrCount, attributes: attributes)
        }
        sax.endElementNs = { ctx, _, _, _ in engine(ctx)?.end() }
        sax.characters = { ctx, text, count in engine(ctx)?.characters(text, count: count) }
        sax.cdataBlock = { ctx, text, count in engine(ctx)?.characters(text, count: count) }
        sax.internalSubset = { ctx, _, _, _ in engine(ctx)?.fail("DTDs and custom entities are prohibited.") }
        sax.externalSubset = { ctx, _, _, _ in engine(ctx)?.fail("External subsets are prohibited.") }
        sax.resolveEntity = { ctx, _, _ in
            engine(ctx)?.fail("External entity resolution is prohibited.")
            return nil
        }
        sax.getEntity = { _, name in xmlGetPredefinedEntity(name) }
        sax.entityDecl = { ctx, _, _, _, _, _ in engine(ctx)?.fail("Custom entities are prohibited.") }
        sax.serror = { ctx, error in
            guard let error, error.pointee.level.rawValue >= XML_ERR_ERROR.rawValue else { return }
            // Never log provider text or external resource names from libxml diagnostics.
            engine(ctx)?.fail(
                "XML syntax error at line \(error.pointee.line), column \(error.pointee.int2) (code \(error.pointee.code))."
            )
        }
        parser = xmlCreatePushParserCtxt(&sax, Unmanaged.passUnretained(self).toOpaque(), nil, 0, nil)
        guard let parser else { throw AgentOutputError.invalidOutput("Could not allocate XML parser.") }
        xmlCtxtUseOptions(parser, Int32(XML_PARSE_NONET.rawValue))
    }
    deinit { if let parser { xmlFreeParserCtxt(parser) } }

    func feed(_ bytes: Data, final: Bool = false) throws -> [(AgentXMLOutputEvent, Int)] {
        guard !finished, let parser else { throw AgentOutputError.protocolViolation("XML parser has finished.") }
        let result = bytes.withUnsafeBytes { pointer in
            xmlParseChunk(
                parser, pointer.baseAddress?.assumingMemoryBound(to: CChar.self), Int32(bytes.count), final ? 1 : 0)
        }
        if final { finished = true }
        if let error { throw error }
        guard result == 0 else { throw AgentOutputError.invalidOutput("Malformed or incomplete XML (code \(result)).") }
        if let version = parser.pointee.version, xmlString(version) != "1.0" {
            throw AgentOutputError.invalidOutput("Only XML 1.0 is supported.")
        }
        if let encoding = parser.pointee.encoding, !["UTF-8", "UTF8"].contains(xmlString(encoding).uppercased()) {
            throw AgentOutputError.invalidOutput("XML output must use UTF-8.")
        }
        let resultEvents = events
        events.removeAll(keepingCapacity: true)
        eventBytes = 0
        return resultEvents
    }

    func fail(_ message: String) {
        fail(.invalidOutput(message))
    }
    func fail(_ failure: AgentOutputError) {
        guard error == nil else { return }
        error = failure
        if let parser { xmlStopParser(parser) }
    }
    func emit(_ event: AgentXMLOutputEvent, size: Int) {
        guard error == nil else { return }
        // A small synchronous callback batch is drained before the next 64-byte feed.
        guard size <= limits.maximumSemanticUnitBytes, events.count < 256,
            size <= limits.maximumQueuedEventBytes - eventBytes
        else {
            fail(.limit("XML callback batch exceeds limit."))
            return
        }
        events.append((event, size))
        eventBytes += size
    }
    func start(
        local: UnsafePointer<xmlChar>?, prefix: UnsafePointer<xmlChar>?, uri: UnsafePointer<xmlChar>?,
        namespaceCount: Int32, namespaces: UnsafeMutablePointer<UnsafePointer<xmlChar>?>?,
        attributeCount: Int32, attributes: UnsafeMutablePointer<UnsafePointer<xmlChar>?>?
    ) {
        guard error == nil else { return }
        guard attributeCount >= 0, namespaceCount >= 0 else {
            fail("Invalid XML attribute or namespace count.")
            return
        }
        guard stack.count < limits.maximumNestingDepth, nodeCount < limits.maximumSemanticUnits,
            attributeCount <= 1_024, namespaceCount <= 1_024
        else {
            fail(.limit("XML depth, element, attribute, or namespace limit exceeded."))
            return
        }
        let name = XMLName(xmlString(local), namespaceURI: optionalXMLString(uri))
        let prefix = xmlString(prefix)
        var bindings: [String: String] = [:], attrs: [XMLName: String] = [:]
        for i in 0..<Int(namespaceCount) { bindings[xmlString(namespaces?[i * 2])] = xmlString(namespaces?[i * 2 + 1]) }
        for i in 0..<Int(attributeCount) {
            guard let attributes, let start = attributes[i * 5 + 3], let end = attributes[i * 5 + 4] else {
                fail("Invalid XML attribute.")
                return
            }
            let attr = XMLName(xmlString(attributes[i * 5]), namespaceURI: optionalXMLString(attributes[i * 5 + 2]))
            guard attrs[attr] == nil else {
                fail("Duplicate expanded XML attribute name.")
                return
            }
            // With entity substitution disabled, SAX2 protects ampersands as
            // &#38;. Decode exactly this one layer, never arbitrary entity text.
            attrs[attr] = String(
                decoding: UnsafeBufferPointer(start: start, count: start.distance(to: end)), as: UTF8.self
            )
            .replacingOccurrences(of: "&#38;", with: "&")
        }
        var path = stack.last?.info.path ?? []
        let index: Int
        if !stack.isEmpty {
            index = (stack[stack.count - 1].siblings[name] ?? 0) + 1
            stack[stack.count - 1].siblings[name] = index
        } else {
            index = 1
        }
        path.append(.init(name: name, index: index))
        nodeCount += 1
        let info = AgentXMLElementInfo(
            id: nodeCount, name: name,
            qualifiedName: prefix.isEmpty ? name.localName : prefix + ":" + name.localName,
            path: path, attributes: attrs, namespaceDeclarations: bindings,
            applicationID: options.identityAttribute.flatMap { attrs[$0] })
        let size = (try? JSONEncoder().encode(info).count) ?? Int.max
        guard size <= limits.maximumOutputBytes - retainedBytes else {
            fail(.limit("XML tree exceeds retained byte limit."))
            return
        }
        retainedBytes += size
        stack.append(Frame(info: info))
        emit(.elementStarted(info), size: size)
    }
    func characters(_ text: UnsafePointer<xmlChar>?, count: Int32) {
        guard error == nil, count > 0, let text, !stack.isEmpty else { return }
        guard Int(count) <= limits.maximumOutputBytes - retainedBytes else {
            fail(.limit("XML text exceeds retained byte limit."))
            return
        }
        retainedBytes += Int(count)
        let value = String(decoding: UnsafeBufferPointer(start: text, count: Int(count)), as: UTF8.self)
        let index = stack.count - 1
        if case .text? = stack[index].content.last,
            case var .text(previous) = stack[index].content.removeLast()
        {
            previous.append(value)
            stack[index].content.append(.text(previous))
        } else {
            stack[index].content.append(.text(value))
        }
        if options.emitTextDeltas {
            emit(.textDelta(elementID: stack[index].info.id, text: value), size: value.utf8.count)
        }
    }
    func end() {
        guard error == nil, let frame = stack.popLast() else { return }
        let element = AgentXMLElement(info: frame.info, content: frame.content)
        emit(.elementEnded(frame.info), size: (try? JSONEncoder().encode(frame.info).count) ?? Int.max)
        if options.completedElements.includes(frame.info.path) {
            emit(.elementCompleted(element), size: (try? JSONEncoder().encode(element).count) ?? Int.max)
        }
        if stack.isEmpty { root = element } else { stack[stack.count - 1].content.append(.element(element)) }
    }
}

private func engine(_ pointer: UnsafeMutableRawPointer?) -> AgentXMLParserEngine? {
    pointer.map { Unmanaged<AgentXMLParserEngine>.fromOpaque($0).takeUnretainedValue() }
}
func xmlString(_ pointer: UnsafePointer<xmlChar>?) -> String { pointer.map { String(cString: $0) } ?? "" }
private func optionalXMLString(_ pointer: UnsafePointer<xmlChar>?) -> String? { pointer.map { String(cString: $0) } }
