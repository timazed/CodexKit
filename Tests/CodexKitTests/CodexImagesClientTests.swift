@testable import CodexKit
import XCTest

final class CodexImagesClientTests: XCTestCase {
    override func setUp() async throws { await TestURLProtocol.reset() }
    override func tearDown() async throws { await TestURLProtocol.reset() }

    // Verify the authenticated ChatGPT Codex host, image request body, and JSON response.
    func testDefaultClientMatchesCodexGenerateContractAndReturnsDiagnostics() async throws {
        let png = try imageTestData(width: 64, height: 32, png: true)
        await TestURLProtocol.enqueue(.init(headers: imageHeaders,
            body: try codexImageJSON(png, extra: ["size": "1024x1024", "background": "transparent"]), inspect: { request in
                XCTAssertEqual(request.url?.absoluteString, "https://chatgpt.com/backend-api/codex/images/generations")
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer demo-access-token")
                XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-ID"), "demo-account")
                XCTAssertEqual(request.value(forHTTPHeaderField: "originator"), "codex_cli_rs")
                let id = try XCTUnwrap(request.value(forHTTPHeaderField: "x-client-request-id"))
                XCTAssertNotNil(UUID(uuidString: id))
                XCTAssertEqual(request.value(forHTTPHeaderField: "x-codex-image-turn-id"), id)
                XCTAssertEqual(try imageRequestJSON(request) as NSDictionary, [
                    "prompt": "Draw a tree", "background": "transparent", "model": "gpt-image-2",
                    "quality": "auto", "size": "auto"
                ] as NSDictionary)
            }))
        let result = try await AgentImageGenerationClient(urlSession: makeTestURLSession()).generate(
            prompt: "Draw a tree", session: demoSession(), options: .init(transparentBackground: true))
        let image = try XCTUnwrap(result.first)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(image.image.data, png)
        XCTAssertEqual(image.image.mimeType, .png)
        XCTAssertEqual(image.pixelSize, .init(width: 64, height: 32))
        XCTAssertEqual(image.image.generationMetadata?.background, "transparent")
        XCTAssertEqual(image.createdAt, Date(timeIntervalSince1970: 1_786_150_000))
        XCTAssertEqual(image.diagnostics?.generationID, "gen-test")
        XCTAssertEqual(image.diagnostics?.requestID, "request-test")
        XCTAssertEqual(image.diagnostics?.imageRequestID, "image-request-test")
        XCTAssertNotNil(image.diagnostics?.clientRequestID)
        XCTAssertEqual(try JSONDecoder().decode(AgentGeneratedImage.self, from: JSONEncoder().encode(image)), image)
    }

    func testEditUsesInlineReferencesAndOpaqueBackgroundWithNoResponsesEnvelope() async throws {
        let refs = (0..<5).map { AgentImageAttachment.jpeg(Data([$0])) }
        await TestURLProtocol.enqueue(.init(headers: imageHeaders, body: try codexImageJSON(), inspect: { request in
            XCTAssertEqual(request.url?.absoluteString, "https://example.invalid/api/codex/images/edits")
            XCTAssertEqual(request.value(forHTTPHeaderField: "originator"), "test-app")
            XCTAssertEqual(request.value(forHTTPHeaderField: "custom-header"), "custom-value")
            let expected: [String: Any] = ["prompt": "Edit", "model": "gpt-image-2", "quality": "auto",
                "size": "auto", "background": "opaque", "images": refs.map { ["image_url": $0.dataURLString] }]
            XCTAssertEqual(try imageRequestJSON(request) as NSDictionary, expected as NSDictionary)
        }))
        let client = AgentImageGenerationClient(configuration: .codexImages(
            baseURL: URL(string: "https://example.invalid/api/codex")!, originator: "test-app",
            extraHeaders: ["custom-header": "custom-value"]), urlSession: makeTestURLSession())
        let result = try await client.edit(images: refs, prompt: "Edit", session: demoSession())
        XCTAssertEqual(result.count, 1)
    }

    func testUnsupportedOptionsAndReferenceCountNeverTransmit() async throws {
        let client = AgentImageGenerationClient(urlSession: makeTestURLSession())
        for options in [AgentImageGenerationOptions(quality: .low), .init(quality: .medium), .init(quality: .high),
                        .init(outputFormat: .jpeg), .init(outputFormat: .webp), .init(action: .edit)] {
            do {
                _ = try await client.generate(prompt: "Draw", session: demoSession(), options: options)
                XCTFail("Unsupported options must not be silently ignored")
            } catch let error as AgentRuntimeError { XCTAssertEqual(error.knownCode, .imageGenerationUnsupportedOptions) }
        }
        do {
            _ = try await client.edit(images: Array(repeating: .png(Data([1])), count: 6), prompt: "Edit", session: demoSession())
            XCTFail("Too many references must be rejected locally")
        } catch let error as AgentRuntimeError { XCTAssertEqual(error.knownCode, .imageGenerationUnsupportedOptions) }
        // No stubs were enqueued; an attempted transmission fails with a different error.
    }

    func testOldOptionsDecodeWithOpaqueDefaultAndCannotRestoreFixedSize() throws {
        let options = try JSONDecoder().decode(AgentImageGenerationOptions.self,
            from: Data(#"{"action":"generate","outputFormat":"png","size":"1024x1024"}"#.utf8))
        XCTAssertFalse(options.transparentBackground)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(options)) as? [String: Any])
        XCTAssertNil(encoded["size"])
        XCTAssertEqual(encoded["transparentBackground"] as? Bool, false)
    }

    func testProviderFailuresPreserveStructuredDetailsWithoutPrivatePayloadsOrRetry() async throws {
        for status in [400, 401, 429, 500] {
            let body = Data(#"{"error":{"code":"invalid_option","type":"invalid_request_error","message":"Invalid image option","private":"PRIVATE_PAYLOAD"}}"#.utf8)
            await TestURLProtocol.enqueue(.init(statusCode: status, headers: imageHeaders, body: body))
            do {
                _ = try await AgentImageGenerationClient(urlSession: makeTestURLSession()).generate(prompt: "Draw", session: demoSession())
                XCTFail("HTTP failure returned success")
            } catch let error as AgentRuntimeError {
                XCTAssertEqual(error.http?.statusCode, status, "A second attempt would consume an absent stub")
                XCTAssertEqual(error.http?.providerCode, "invalid_option")
                XCTAssertEqual(error.http?.providerType, "invalid_request_error")
                XCTAssertEqual(error.message, "Invalid image option")
                XCTAssertEqual(error.imageGeneration?.imageRequestID, "image-request-test")
                XCTAssertEqual(error.imageGeneration?.requestID, "request-test")
                XCTAssertNotNil(error.imageGeneration?.clientRequestID)
                let serialized = String(decoding: try JSONEncoder().encode(error), as: UTF8.self)
                XCTAssertFalse(serialized.contains("PRIVATE_PAYLOAD"))
                XCTAssertFalse(serialized.contains("access-token"))
            }
        }
    }

    func testQuotaUsesBodyResetOrExhaustedHeaderWindowsAndAllowsUnknownReset() async throws {
        for bodyReset in [true, false] {
            var headers = imageHeaders
            headers["x-codex-active-limit"] = "image_gen"
            headers["x-image-gen-primary-used-percent"] = "100"
            headers["x-image-gen-primary-reset-at"] = "2000"
            headers["x-image-gen-secondary-used-percent"] = "100"
            headers["x-image-gen-secondary-reset-at"] = "3000"
            let error: [String: Any] = bodyReset ? ["type": "usage_limit_reached", "resets_at": 4000] : ["type": "usage_limit_reached"]
            await TestURLProtocol.enqueue(.init(statusCode: 429, headers: headers,
                body: try JSONSerialization.data(withJSONObject: ["error": error])))
            let failure = try await failureForNextResponse()
            XCTAssertEqual(failure.knownCode, .imageGenerationUsageLimitExceeded)
            XCTAssertEqual(failure.imageGeneration?.usageLimit?.limitID, "image_gen")
            XCTAssertEqual(failure.imageGeneration?.usageLimit?.resetsAt, Date(timeIntervalSince1970: bodyReset ? 4000 : 3000))
            XCTAssertEqual(try JSONDecoder().decode(AgentRuntimeError.self, from: JSONEncoder().encode(failure)), failure)
        }
        await TestURLProtocol.enqueue(.init(statusCode: 429, headers: ["x-codex-active-limit": "image_gen"],
            body: Data(#"{"error":{"type":"usage_limit_reached"}}"#.utf8)))
        let failure = try await failureForNextResponse()
        XCTAssertEqual(failure.imageGeneration?.usageLimit?.limitID, "image_gen")
        XCTAssertNil(failure.imageGeneration?.usageLimit?.resetsAt)
        await TestURLProtocol.enqueue(.init(statusCode: 429, headers: ["x-codex-active-limit": "codex"],
            body: Data(#"{"error":{"type":"usage_limit_reached"}}"#.utf8)))
        let other = try await failureForNextResponse()
        XCTAssertNil(other.imageGeneration?.usageLimit)
        XCTAssertEqual(other.code, "image_generation_http_status_429")
    }

    func testMalformedMissingPartialAndErrorResponsesNeverSucceed() async throws {
        let png = try imageTestData(width: 8, height: 8, png: true)
        let bodies = [
            Data("{\"private\":\"PRIVATE_PAYLOAD\"".utf8),
            Data(#"{"created":1,"data":[]}"#.utf8),
            Data(#"{"created":1,"data":[{"b64_json":"not-base64"}]}"#.utf8),
            try codexImageJSON(Data(png.prefix(png.count / 2))),
            try codexImageJSON(try imageTestData(width: 8, height: 8)), // Unexpected JPEG, not mislabeled PNG.
            try codexImageJSON(png, extra: ["status": "incomplete"]),
            try codexImageJSON(png, extra: ["status": "failed"]),
            try codexImageJSON(png, extra: ["error": ["type": "server_error", "message": "Image failed"]])
        ]
        for body in bodies {
            await TestURLProtocol.enqueue(.init(headers: imageHeaders, body: body))
            let error = try await failureForNextResponse()
            XCTAssertTrue([.imageGenerationInvalidResponse, .imageGenerationMissingOutput].contains(error.knownCode))
            XCTAssertEqual(error.imageGeneration?.imageRequestID, "image-request-test")
            XCTAssertFalse(error.message.contains("PRIVATE_PAYLOAD"))
        }
    }

    func testResponseByteLimitIsEnforcedWithAndWithoutContentLength() async throws {
        for declared in [false, true] {
            var headers = imageHeaders
            if declared { headers["Content-Length"] = "2048" }
            await TestURLProtocol.enqueue(.init(headers: headers, body: Data(repeating: 65, count: 2048)))
            do {
                _ = try await CodexImagesClient(configuration: .codexImages(), urlSession: makeTestURLSession(), maximumResponseBytes: 64)
                    .run(prompt: "Draw", images: [], session: demoSession(), options: .generate)
                XCTFail("Oversized body was accepted")
            } catch let error as AgentRuntimeError {
                XCTAssertEqual(error.knownCode, .imageGenerationResponseTooLarge)
                XCTAssertEqual(error.imageGeneration?.imageRequestID, "image-request-test")
            }
        }
    }

    func testProviderMessageShapesAndHTTP200ErrorsArePreserved() async throws {
        for key in ["error", "message", "detail"] {
            await TestURLProtocol.enqueue(.init(statusCode: 400, headers: imageHeaders,
                body: try JSONSerialization.data(withJSONObject: [key: "Provider explanation"])))
            let error = try await failureForNextResponse()
            XCTAssertEqual(error.message, "Provider explanation")
        }
        await TestURLProtocol.enqueue(.init(headers: imageHeaders,
            body: Data(#"{"error":"Image generation failed"}"#.utf8)))
        let error = try await failureForNextResponse()
        XCTAssertEqual(error.message, "Image generation failed")
        XCTAssertEqual(error.http?.statusCode, 200)
        XCTAssertEqual(error.knownCode, .imageGenerationInvalidResponse)
    }

    func testMissingOptionalIDsAndOldErrorSerializationRemainCompatible() async throws {
        let old = try JSONDecoder().decode(AgentRuntimeError.self, from: Data(#"{"code":"old","message":"Old error"}"#.utf8))
        XCTAssertNil(old.imageGeneration)
        let body: [String: Any] = ["created": 1, "data": [["b64_json": try imageTestData(width: 8, height: 8, png: true).base64EncodedString()]]]
        await TestURLProtocol.enqueue(.init(headers: ["Content-Type": "application/json"],
            body: try JSONSerialization.data(withJSONObject: body)))
        let images = try await AgentImageGenerationClient(urlSession: makeTestURLSession()).generate(
            prompt: "Draw", session: demoSession(), options: .init(quality: .auto))
        XCTAssertNil(images.first?.diagnostics?.generationID)
        XCTAssertNil(images.first?.diagnostics?.imageRequestID)
        XCTAssertNil(images.first?.diagnostics?.requestID)
        XCTAssertNotNil(images.first?.diagnostics?.clientRequestID)
    }

    private func failureForNextResponse() async throws -> AgentRuntimeError {
        do {
            _ = try await AgentImageGenerationClient(urlSession: makeTestURLSession()).generate(prompt: "Draw", session: demoSession())
            XCTFail("Expected failure")
            throw CancellationError()
        } catch let error as AgentRuntimeError { return error }
    }
}

private let imageHeaders = ["Content-Type": "application/json", "x-request-id": "request-test",
    "x-codex-imagegen-request-id": "image-request-test"]

func codexImageJSON(_ data: Data? = nil, extra: [String: Any] = [:]) throws -> Data {
    let data = try data ?? imageTestData(width: 8, height: 8, png: true)
    var value: [String: Any] = ["created": 1_786_150_000,
        "data": [["b64_json": data.base64EncodedString(), "generation_id": "gen-test"]]]
    value.merge(extra) { _, new in new }
    return try JSONSerialization.data(withJSONObject: value)
}
