@testable import CodexKit
import ImageIO
import UniformTypeIdentifiers
import XCTest

final class AnimatedImageOutputTests: XCTestCase {
    override func setUp() async throws { await TestURLProtocol.reset() }
    override func tearDown() async throws { await TestURLProtocol.reset() }

    func testGenerateAndEditPreserveGIFBytesAndFrameControls() async throws {
        let gif = animatedGIF()
        for edit in [false, true] {
            await TestURLProtocol.enqueue(.init(headers: ["Content-Type": "application/json"], body: try codexImageJSON(gif), inspect: { request in
                let body = try imageRequestJSON(request)
                XCTAssertEqual(body["output_format"] as? String, "gif")
                XCTAssertEqual(body["gif"] as? [String: Int], ["frame_count": 2, "frame_duration_ms": 100])
                XCTAssertTrue(request.url?.path.hasSuffix(edit ? "images/edits" : "images/generations") == true)
            }))
            var options = AgentImageGenerationOptions(outputFormat: .gif)
            options.animation = .init(frameCount: 2, frameDurationMilliseconds: 100)
            let restored = try JSONDecoder().decode(AgentImageGenerationOptions.self, from: JSONEncoder().encode(options))
            let client = AgentImageGenerationClient(urlSession: makeTestURLSession())
            let result = try await (edit
                ? client.edit(images: [.png(try imageTestData(width: 1, height: 1, png: true))], prompt: "Animate", session: demoSession(), options: restored)
                : client.generate(prompt: "Animate", session: demoSession(), options: restored))
            let image = try XCTUnwrap(result.first)
            XCTAssertEqual(image.image.mimeType, .gif)
            XCTAssertEqual(image.image.data, gif)
            XCTAssertEqual(image.image.generationMetadata?.outputFormat, "gif")
            XCTAssertEqual(image.pixelSize, .init(width: 1, height: 1))
            XCTAssertEqual(try JSONDecoder().decode(AgentGeneratedImage.self, from: JSONEncoder().encode(image)), image)
        }
    }

    func testDefaultGIFOptionsEmitEmptyControls() async throws {
        await TestURLProtocol.enqueue(.init(headers: ["Content-Type": "application/json"], body: try codexImageJSON(animatedGIF()), inspect: { request in
            let body = try imageRequestJSON(request)
            XCTAssertEqual(body["gif"] as? [String: Int], [:])
        }))
        _ = try await AgentImageGenerationClient(urlSession: makeTestURLSession()).generate(prompt: "Animate",
            session: demoSession(), options: .init(outputFormat: .gif))
    }

    func testInvalidControlsAndLegacyResponsesGIFNeverTransmit() async throws {
        for controls in [AgentGIFOptions(frameCount: 1), .init(frameCount: 17),
                         .init(frameDurationMilliseconds: 19), .init(frameDurationMilliseconds: 2_001)] {
            var options = AgentImageGenerationOptions(outputFormat: .gif)
            options.animation = controls
            do {
                _ = try await AgentImageGenerationClient(urlSession: makeTestURLSession()).generate(prompt: "Animate",
                    session: demoSession(), options: options)
                XCTFail("Invalid options accepted")
            } catch { XCTAssertEqual((error as? AgentRuntimeError)?.knownCode, .imageGenerationUnsupportedOptions) }
        }
        do {
            _ = try await AgentImageGenerationClient(configuration: .init(), urlSession: makeTestURLSession()).generate(
                prompt: "Animate", session: demoSession(), options: .init(outputFormat: .gif))
            XCTFail("Legacy Responses GIF accepted")
        } catch { XCTAssertEqual((error as? AgentRuntimeError)?.knownCode, .imageGenerationUnsupportedOptions) }
    }

    func testMalformedGIFAndUnexpectedPNGAreRejected() async throws {
        for bytes in [Data(animatedGIF().dropLast()), Data(animatedGIF().dropLast(4)), try imageTestData(width: 1, height: 1, png: true)] {
            await TestURLProtocol.enqueue(.init(headers: ["Content-Type": "application/json"], body: try codexImageJSON(bytes)))
            do {
                _ = try await AgentImageGenerationClient(urlSession: makeTestURLSession()).generate(prompt: "Animate",
                    session: demoSession(), options: .init(outputFormat: .gif))
                XCTFail("Invalid animation accepted")
            } catch { XCTAssertEqual((error as? AgentRuntimeError)?.knownCode, .imageGenerationInvalidResponse) }
        }
    }

    func testFollowUpRequestUsesPNGPreviewWithoutChangingStoredAnimation() throws {
        let image = AgentImageAttachment(mimeType: .gif, data: animatedGIF())
        let original = WorkingHistoryItem.userMessage(.init(threadID: "t", role: .user, text: "Inspect", images: [image])).jsonValue
        let factory = CodexResponsesRequestFactory(configuration: .init(), encoder: JSONEncoder())
        let request = try factory.buildURLRequest(model: "test", instructions: "", input: [original], tools: [],
            toolChoice: .none, requestID: "t", session: demoSession())
        let body = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(request.httpBody))
        let parts = try XCTUnwrap(body.objectValue?["input"]?.arrayValue?.first?.objectValue?["content"]?.arrayValue)
        let preview = try XCTUnwrap(parts.last?.objectValue?["image_url"]?.stringValue)
        XCTAssertTrue(preview.hasPrefix("data:image/png;base64,"))
        XCTAssertEqual(image.data, animatedGIF())
        XCTAssertEqual(original.objectValue?["content"]?.arrayValue?.last?.objectValue?["image_url"], .string(image.dataURLString))
    }

    private func animatedGIF() -> Data {
        // Two 1×1 frames, each with a complete clear/pixel/end LZW stream.
        let header: [UInt8] = Array("GIF89a".utf8) + [1, 0, 1, 0, 128, 0, 0, 0, 0, 0, 255, 255, 255]
        let frame: [UInt8] = [0x21, 0xf9, 4, 0, 10, 0, 0, 0, 0x2c, 0, 0, 0, 0, 1, 0, 1, 0, 0, 2, 2, 0x44, 1, 0]
        return Data(header + frame + frame + [0x3b])
    }
}
