import CodexKit
import XCTest

final class AgentImageGenerationClientTests: XCTestCase {
    override func tearDown() {
        let expectation = XCTestExpectation(description: "reset protocol stubs")
        Task {
            await TestURLProtocol.reset()
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
        super.tearDown()
    }

    func testEditSendsInputImagesAndDecodesGeneratedImage() async throws {
        let client = AgentImageGenerationClient(urlSession: makeTestURLSession())
        let session = ChatGPTSession(
            accessToken: "access-token",
            refreshToken: "refresh-token",
            account: ChatGPTAccount(id: "workspace-123", email: "taylor@example.com", plan: .plus)
        )
        let sourceImage = AgentImageAttachment.jpeg(Data([0x01, 0x02, 0x03]), id: "source-image")
        let generatedBytes = Data([0x89, 0x50, 0x4E, 0x47])

        await TestURLProtocol.enqueue(
            .init(
                headers: ["Content-Type": "application/json"],
                body: Data(
                    """
                    {
                      "id": "resp_image",
                      "output": [
                        {
                          "id": "ig_123",
                          "type": "image_generation_call",
                          "status": "completed",
                          "revised_prompt": "Make the background transparent.",
                          "result": "\(generatedBytes.base64EncodedString())"
                        }
                      ]
                    }
                    """.utf8
                ),
                inspect: { request in
                    XCTAssertEqual(request.httpMethod, "POST")
                    XCTAssertEqual(request.url?.absoluteString, "https://chatgpt.com/backend-api/codex/responses")
                    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-token")
                    XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-ID"), "workspace-123")
                    XCTAssertEqual(request.value(forHTTPHeaderField: "originator"), "codex_cli_rs")

                    let body = try XCTUnwrap(requestBodyData(for: request))
                    let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
                    XCTAssertEqual(json?["model"] as? String, "gpt-5")
                    XCTAssertEqual(json?["store"] as? Bool, false)

                    let tools = try XCTUnwrap(json?["tools"] as? [[String: Any]])
                    XCTAssertEqual(tools.first?["type"] as? String, "image_generation")
                    XCTAssertEqual(tools.first?["model"] as? String, "gpt-image-1.5")
                    XCTAssertEqual(tools.first?["action"] as? String, "edit")
                    XCTAssertEqual(tools.first?["output_format"] as? String, "png")

                    let input = try XCTUnwrap(json?["input"] as? [[String: Any]])
                    let content = try XCTUnwrap(input.first?["content"] as? [[String: Any]])
                    XCTAssertEqual(content.first?["type"] as? String, "input_text")
                    XCTAssertEqual(content.first?["text"] as? String, "Remove the background.")
                    XCTAssertEqual(content.dropFirst().first?["type"] as? String, "input_image")
                    XCTAssertEqual(content.dropFirst().first?["image_url"] as? String, sourceImage.dataURLString)
                }
            )
        )

        let results = try await client.edit(
            images: [sourceImage],
            prompt: "Remove the background.",
            session: session
        )

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.id, "ig_123")
        XCTAssertEqual(results.first?.revisedPrompt, "Make the background transparent.")
        XCTAssertEqual(results.first?.image.mimeType, .png)
        XCTAssertEqual(results.first?.image.data, generatedBytes)
    }

    func testEditRejectsUnsupportedSourceImageMimeType() async throws {
        let client = AgentImageGenerationClient(urlSession: makeTestURLSession())
        let session = ChatGPTSession(
            accessToken: "access-token",
            account: ChatGPTAccount(id: "workspace-123", email: "taylor@example.com", plan: .plus)
        )
        let unsupported = AgentImageAttachment(
            mimeType: "image/gif",
            data: Data([0x47, 0x49, 0x46])
        )

        do {
            _ = try await client.edit(
                images: [unsupported],
                prompt: "Make this realistic.",
                session: session
            )
            XCTFail("GIF image edits should be rejected before request construction")
        } catch let error as AgentRuntimeError {
            XCTAssertEqual(error.code, "unsupported_image_mime_type")
        }
    }
}
