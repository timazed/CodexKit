import CodexKit
import ImageIO
import UniformTypeIdentifiers
import XCTest

final class AgentImageGenerationSizeTests: XCTestCase {
    override func setUp() async throws { await TestURLProtocol.reset() }
    override func tearDown() async throws { await TestURLProtocol.reset() }

    func testReportedDimensionsUseImageBytesRatherThanProviderMetadata() async throws {
        let data = try imageTestData(width: 64, height: 32)
        let item = imageItem(result: data.base64EncodedString(), format: "jpeg")
            .dropLast() + #","size":"1024x1024"}"#
        await TestURLProtocol.enqueue(.init(body: imageSSE(imageDone(String(item)), imageCompleted([]))))
        let images = try await AgentImageGenerationClient(urlSession: makeTestURLSession()).generate(
            prompt: "Draw", session: demoSession(), options: .init(outputFormat: .jpeg, quality: .low))
        XCTAssertEqual(images.first?.pixelSize, .init(width: 64, height: 32))
        XCTAssertEqual(images.first?.image.pixelSize, .init(width: 64, height: 32))
        XCTAssertEqual(images.first?.image.data, data, "Reporting must not resize or re-encode")
    }

    func testPersistedLegacySizeCannotBecomeARequestOption() async throws {
        let legacy = Data(#"{"action":"generate","outputFormat":"jpeg","quality":"low","size":"1024x1024"}"#.utf8)
        let options = try JSONDecoder().decode(AgentImageGenerationOptions.self, from: legacy)
        XCTAssertEqual(options, .init(action: .generate, outputFormat: .jpeg, quality: .low))
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(options)) as? [String: Any])
        XCTAssertEqual(Set(encoded.keys), ["action", "outputFormat", "quality"])
        let data = try imageTestData(width: 1254, height: 1254)
        await TestURLProtocol.enqueue(.init(body: imageSSE(imageCompleted([
            imageItem(result: data.base64EncodedString(), format: "jpeg")
        ])), inspect: { request in
            let body = try imageRequestJSON(request)
            let tool = try XCTUnwrap((body["tools"] as? [[String: Any]])?.first)
            XCTAssertNil(tool["size"])
            XCTAssertEqual(tool["quality"] as? String, "low")
        }))
        let images = try await AgentImageGenerationClient(urlSession: makeTestURLSession()).generate(
            prompt: "Draw", session: demoSession(), options: options)
        XCTAssertEqual(images.first?.pixelSize, .init(width: 1254, height: 1254))
        XCTAssertEqual(images.first?.image.data, data)
    }

    func testUnreadableBytesDoNotInventDimensions() {
        let image = AgentGeneratedImage(id: "invalid", image: .jpeg(Data([1, 2, 3])))
        XCTAssertNil(image.pixelSize)
    }

    func testPNGDimensionsRemainAvailableAfterResultSerialization() throws {
        let image = AgentGeneratedImage(id: "png", image: .png(try imageTestData(width: 32, height: 64, png: true)))
        let restored = try JSONDecoder().decode(AgentGeneratedImage.self, from: JSONEncoder().encode(image))
        XCTAssertEqual(restored.pixelSize, .init(width: 32, height: 64))
        XCTAssertEqual(restored.image.data, image.image.data)
    }
}

func imageTestData(width: Int, height: Int, png: Bool = false) throws -> Data {
    let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(CGColor(gray: 0.4, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let data = NSMutableData()
    let type = png ? UTType.png : .jpeg
    let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return data as Data
}
