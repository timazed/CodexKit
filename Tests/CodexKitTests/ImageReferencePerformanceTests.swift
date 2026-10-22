@testable import CodexKit
import CryptoKit
import XCTest

final class ImageReferencePerformanceTests: XCTestCase {
    func testRepeatedMixedReferencesKeepFirstAttachmentMetadataAndRejectMissingData() throws {
        let first = AgentImageAttachment.png(Data("same image".utf8))
        let duplicate = AgentImageAttachment(mimeType: "image/jpeg", data: first.data)
        let refs = try CodexResponsesImageReferences.externalize([
            .object(["image_url": .string(first.dataURLString)]),
            .object(["b64_json": .string(first.data.base64EncodedString())])])
        let nested = [JSONValue.array(refs + refs)]
        let actual = try CodexResponsesImageReferences.restore(nested, using: [first, duplicate])
        XCTAssertEqual(actual, try legacyRestore(nested, attachments: [first, duplicate]))
        XCTAssertThrowsError(try CodexResponsesImageReferences.restore(nested, using: []))
        XCTAssertEqual(try CodexResponsesImageReferences.restore([.string("plain")], using: [first]), [.string("plain")])
    }

    func testImageExpansionBenchmark() throws {
        guard ProcessInfo.processInfo.environment["CODEXKIT_RUN_PERFORMANCE_TESTS"] == "1" else {
            throw XCTSkip("Opt-in image reference benchmark")
        }
        let attachments = (0..<8).map { AgentImageAttachment.png(Data(repeating: UInt8($0), count: 1_000_000)) }
        let reference = try CodexResponsesImageReferences.externalize([
            .object(["image_url": .string(attachments[0].dataURLString)])])[0]
        for (name, items) in [("no_references", [JSONValue.string("plain")]),
                              ("repeated_reference", Array(repeating: reference, count: 8))] {
            var oldTimes: [Double] = [], newTimes: [Double] = []
            for _ in 0..<5 {
                let oldStart = ContinuousClock.now
                let old = try legacyRestore(items, attachments: attachments)
                oldTimes.append(ms(oldStart.duration(to: .now)))
                let newStart = ContinuousClock.now
                let new = try CodexResponsesImageReferences.restore(items, using: attachments)
                newTimes.append(ms(newStart.duration(to: .now)))
                XCTAssertEqual(new, old)
            }
            print("BENCHMARK image_restore workload=\(name) attachment_bytes=8000000 old_median_ms=\(oldTimes.sorted()[2]) new_median_ms=\(newTimes.sorted()[2])")
        }
    }

    // Original eager hashing and per-occurrence encoding, retained as the baseline.
    private func legacyRestore(_ items: [JSONValue], attachments: [AgentImageAttachment]) throws -> [JSONValue] {
        let byDigest = Dictionary(attachments.map {
            (SHA256.hash(data: $0.data).map { String(format: "%02x", $0) }.joined(), $0)
        }, uniquingKeysWith: { first, _ in first })
        func restore(_ value: JSONValue) throws -> JSONValue {
            switch value {
            case let .array(values): return .array(try values.map(restore))
            case let .object(object): return .object(try object.mapValues(restore))
            case let .string(text):
                for prefix in ["codexkit-image-ref:data-url:", "codexkit-image-ref:base64:"] where text.hasPrefix(prefix) {
                    let attachment = try XCTUnwrap(byDigest[String(text.dropFirst(prefix.count))])
                    return .string(prefix.contains("data-url") ? attachment.dataURLString : attachment.data.base64EncodedString())
                }
                return value
            default: return value
            }
        }
        return try items.map(restore)
    }

    private func ms(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }
}
