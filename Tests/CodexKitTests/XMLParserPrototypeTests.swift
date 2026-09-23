@testable import CodexKit
import Foundation
import XCTest

/// Spike retained as executable evidence for the Foundation vs push-parser decision.
final class XMLParserPrototypeTests: XCTestCase {
    func testFoundationBoundedInputStreamDeliversBeforeEOFAndCancelsBlockedRead() async throws {
        for cancel in [false, true] {
            let input = XMLProbeInputStream(capacity: 256)
            let subtree = expectation(description: "subtree closes before EOF")
            let finished = expectation(description: "worker exits")
            let outcome = XMLProbeResult()
            DispatchQueue.global().async {
                let delegate = XMLProbeDelegate { subtree.fulfill() }
                let parser = XMLParser(stream: input)
                parser.delegate = delegate
                parser.shouldResolveExternalEntities = false
                outcome.record(parser.parse())
                finished.fulfill()
            }
            input.write(Data("<r><item>😀</item>".utf8))
            await fulfillment(of: [subtree], timeout: 3)
            if cancel { input.cancelRead() }
            else { input.write(Data("</r>".utf8)); input.finish() }
            await fulfillment(of: [finished], timeout: 3)
            XCTAssertEqual(outcome.value, !cancel)
            XCTAssertLessThanOrEqual(input.peakBytes, 256)
        }
    }

    func testPushParserMatchesFoundationForUnicodeChunkBoundaries() throws {
        let source = Data("<r><item a=\"one &amp; two\">before<![CDATA[😀 <raw>]]>after</item></r>".utf8)
        let reference = XMLParser(data: source)
        XCTAssertTrue(reference.parse())
        for chunk in [1, 2, 3, 7, 64, 1_024] {
            let parser = try AgentXMLParserEngine(limits: .init(), options: .init())
            for offset in stride(from: 0, to: source.count, by: chunk) {
                _ = try parser.feed(Data(source[offset ..< min(offset + chunk, source.count)]))
            }
            _ = try parser.feed(Data(), final: true)
            XCTAssertEqual(parser.root?.text, "before😀 <raw>after")
            XCTAssertEqual(parser.root?.children.first?.attributes["a"], "one & two")
        }
    }
}

private final class XMLProbeResult: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Bool?
    func record(_ value: Bool) { lock.withLock { result = value } }
    var value: Bool? { lock.withLock { result } }
}
private final class XMLProbeDelegate: NSObject, XMLParserDelegate {
    let closed: @Sendable () -> Void
    init(closed: @escaping @Sendable () -> Void) { self.closed = closed }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "item" { closed() }
    }
}

private final class XMLProbeInputStream: InputStream, @unchecked Sendable {
    private let condition = NSCondition()
    private let capacity: Int
    private var bytes = Data()
    private var eof = false
    private var cancelled = false
    private var peak = 0
    init(capacity: Int) { self.capacity = capacity; super.init(data: Data()) }
    override func open() {}
    override func close() { finish() }
    override var hasBytesAvailable: Bool { condition.withLock { !bytes.isEmpty || !eof } }
    override var streamStatus: Stream.Status { condition.withLock { cancelled ? .error : (eof && bytes.isEmpty ? .atEnd : .open) } }
    override var streamError: Error? { condition.withLock { cancelled ? CancellationError() : nil } }
    override func getBuffer(_ buffer: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>, length len: UnsafeMutablePointer<Int>) -> Bool { false }
    override func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength len: Int) -> Int {
        condition.lock(); defer { condition.broadcast(); condition.unlock() }
        while bytes.isEmpty && !eof && !cancelled {
            if !condition.wait(until: Date().addingTimeInterval(3)) { cancelled = true }
        }
        if cancelled { return -1 }
        let count = min(len, bytes.count)
        bytes.copyBytes(to: buffer, count: count)
        bytes = Data(bytes.dropFirst(count))
        return count
    }
    func write(_ input: Data) {
        condition.lock(); defer { condition.broadcast(); condition.unlock() }
        for byte in input {
            while bytes.count == capacity && !cancelled {
                condition.broadcast()
                if !condition.wait(until: Date().addingTimeInterval(3)) { cancelled = true }
            }
            guard !cancelled else { return }
            bytes.append(byte); peak = max(peak, bytes.count)
        }
    }
    func finish() { condition.withLock { eof = true; condition.broadcast() } }
    func cancelRead() { condition.withLock { cancelled = true; condition.broadcast() } }
    var peakBytes: Int { condition.withLock { peak } }
}
