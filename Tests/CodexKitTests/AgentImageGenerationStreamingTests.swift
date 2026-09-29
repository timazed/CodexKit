import CodexKit
import XCTest

final class AgentImageGenerationStreamingTests: XCTestCase {
    override func setUp() async throws { await TestURLProtocol.reset() }
    override func tearDown() async throws { await TestURLProtocol.reset() }

    func testAccountModelLowQualityJPEGEditUsesCodexStreamingContract() async throws {
        let source = AgentImageAttachment.jpeg(Data([0xFF, 0xD8, 0xFF]), id: "photo")
        let generated = try imageTestData(width: 1024, height: 1024)
        let urlConfiguration = URLSessionConfiguration.ephemeral
        urlConfiguration.protocolClasses = [TestURLProtocol.self]
        urlConfiguration.timeoutIntervalForRequest = 987
        let urlSession = URLSession(configuration: urlConfiguration)
        defer { urlSession.invalidateAndCancel() }
        let client = AgentImageGenerationClient(configuration: .init(
            model: "gpt-6-astra", imageModel: nil, originator: "pocket-potus",
            extraHeaders: ["X-App": "portrait"]), urlSession: urlSession)
        await TestURLProtocol.enqueue(.init(headers: ["Content-Type": "text/event-stream"],
            body: imageSSE(imageCompleted([imageItem(result: generated.base64EncodedString(), format: "jpeg")])), inspect: { request in
                XCTAssertEqual(request.url?.absoluteString, "https://chatgpt.com/backend-api/codex/responses")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
                XCTAssertEqual(request.value(forHTTPHeaderField: "originator"), "pocket-potus")
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-App"), "portrait")
                XCTAssertEqual(request.timeoutInterval, urlSession.configuration.timeoutIntervalForRequest)
                let json = try imageRequestJSON(request)
                XCTAssertEqual(json["model"] as? String, "gpt-6-astra")
                XCTAssertEqual(json["stream"] as? Bool, true)
                XCTAssertEqual(json["store"] as? Bool, false)
                XCTAssertNotNil(json["instructions"] as? String)
                XCTAssertNil(json["reasoning"], "Do not invent a reasoning effort for an account-discovered model")
                XCTAssertEqual(json["tool_choice"] as? [String: String], ["type": "image_generation"])
                let tool = try XCTUnwrap((json["tools"] as? [[String: Any]])?.first)
                XCTAssertEqual(tool["type"] as? String, "image_generation")
                XCTAssertNil(tool["model"], "nil imageModel must be omitted, not substituted")
                XCTAssertEqual(tool["action"] as? String, "edit")
                XCTAssertEqual(tool["quality"] as? String, "low")
                XCTAssertNil(tool["size"])
                XCTAssertEqual(tool["output_format"] as? String, "jpeg")
                let input = try XCTUnwrap(json["input"] as? [[String: Any]])
                let content = try XCTUnwrap(input.first?["content"] as? [[String: Any]])
                XCTAssertEqual(content.last?["image_url"] as? String, source.dataURLString)
            }))
        let images = try await client.edit(images: [source], prompt: "Portrait", session: demoSession(),
            options: .init(action: .edit, outputFormat: .jpeg, quality: .low))
        XCTAssertEqual(images.map(\.image.mimeType), [.jpeg])
        XCTAssertEqual(images.first?.image.data, generated)
    }

    func testAutoResolutionPreservesOptionsForGenerateAndEdit() async throws {
        let generated = try imageTestData(width: 1024, height: 1024, png: true)
        for action in ["generate", "edit"] {
            await TestURLProtocol.enqueue(.init(body: imageSSE(imageCompleted([imageItem(result: generated.base64EncodedString())])), inspect: { request in
                let json = try imageRequestJSON(request)
                XCTAssertEqual(json["tool_choice"] as? [String: String], ["type": "image_generation"])
                let tool = try XCTUnwrap((json["tools"] as? [[String: Any]])?.first)
                XCTAssertEqual(tool["action"] as? String, action)
                XCTAssertEqual(tool["quality"] as? String, "low")
                XCTAssertNil(tool["size"])
                XCTAssertEqual(tool["output_format"] as? String, "png")
            }))
            let client = AgentImageGenerationClient(configuration: .init(), urlSession: makeTestURLSession())
            let options = AgentImageGenerationOptions(action: .auto, outputFormat: .png, quality: .low)
            let images = if action == "generate" {
                try await client.generate(prompt: "Draw", session: demoSession(), options: options)
            } else {
                try await client.edit(images: [.jpeg(Data([1]))], prompt: "Edit", session: demoSession(), options: options)
            }
            XCTAssertEqual(images.first?.image.mimeType, .png, "Use requested format when the provider omits output_format")
        }
    }

    func testQualityOnlyGenerateAndEditOmitSizeAndPreserveProviderPixels() async throws {
        let generated = try imageTestData(width: 1254, height: 1254)
        for quality in [AgentImageGenerationQuality.low, .medium, .high, .auto] {
            for edit in [false, true] {
                await TestURLProtocol.enqueue(.init(body: imageSSE(imageCompleted([
                    imageItem(result: generated.base64EncodedString(), format: "jpeg")
                ])), inspect: { request in
                    let body = try imageRequestJSON(request)
                    XCTAssertEqual(body["model"] as? String, "gpt-6-astra")
                    let tool = try XCTUnwrap((body["tools"] as? [[String: Any]])?.first)
                    XCTAssertNil(tool["size"])
                    XCTAssertNil(tool["model"])
                    XCTAssertEqual(tool["quality"] as? String, quality.rawValue)
                    XCTAssertEqual(tool["output_format"] as? String, "jpeg")
                    XCTAssertEqual(tool["action"] as? String, edit ? "edit" : "generate")
                }))
                let client = AgentImageGenerationClient(configuration: .init(model: "gpt-6-astra", imageModel: nil),
                    urlSession: makeTestURLSession())
                let options = AgentImageGenerationOptions(outputFormat: .jpeg, quality: quality)
                let images = if edit {
                    try await client.edit(images: [.jpeg(generated)], prompt: "Edit", session: demoSession(), options: options)
                } else {
                    try await client.generate(prompt: "Draw", session: demoSession(), options: options)
                }
                XCTAssertEqual(images.first?.pixelSize, .init(width: 1254, height: 1254))
                XCTAssertEqual(images.first?.image.data, generated)
            }
        }
    }

    func testTerminalSnapshotReconcilesProvisionalImagesWithoutDuplicates() async throws {
        let provisional = imageItem(id: "first", result: "BAUG")
        let final = imageItem(id: "first", result: "AQID", format: "jpeg")
        await TestURLProtocol.enqueue(.init(body: imageSSE(
            imageDone(provisional), imageCompleted([final, imageItem(id: "second")]))))
        let images = try await generate()
        XCTAssertEqual(images.map(\.id), ["first", "second"])
        XCTAssertEqual(images.first?.image.data, Data([1, 2, 3]))
        XCTAssertEqual(images.first?.image.mimeType, .jpeg)
        XCTAssertEqual(images.first?.image.generationMetadata?.outputFormat, "jpeg")
        XCTAssertEqual(images.first?.image.generationMetadata?.status, "completed")
    }

    func testEmptyCodexTerminalOutputRetainsFinalizedStreamImages() async throws {
        await TestURLProtocol.enqueue(.init(body: imageSSE(
            imageDone(imageItem(format: "jpeg")), imageCompleted([]))))
        let images = try await generate()
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(images.first?.image.data, Data([1, 2, 3]))
        XCTAssertEqual(images.first?.image.mimeType, .jpeg)
    }

    func testEmptyTerminalOutputCannotPromoteUnfinishedStreamImage() async throws {
        await TestURLProtocol.enqueue(.init(body: imageSSE(
            imageDone(imageItem(status: "in_progress")), imageCompleted([]))))
        let error = try await failure()
        XCTAssertEqual(error.code, "image_generation_invalid_response")
    }

    func testCodexGeneratingLabelRequiresFinalizedItemAndTerminalSuccess() async throws {
        let finalized = imageItem(status: "generating")
        await TestURLProtocol.enqueue(.init(body: imageSSE(imageDone(finalized), imageCompleted([]))))
        let images = try await generate()
        XCTAssertEqual(images.first?.image.data, Data([1, 2, 3]))

        XCTAssertEqual(images.first?.image.generationMetadata?.status, "generating")

        await TestURLProtocol.enqueue(.init(body: imageSSE(imageCompleted([finalized]))))
        let unfinished = try await failure()
        XCTAssertEqual(unfinished.code, "image_generation_invalid_response")

        await TestURLProtocol.enqueue(.init(body: imageSSE(imageDone(finalized))))
        let disconnected = try await failure()
        XCTAssertEqual(disconnected.code, "responses_stream_disconnected")
    }

    func testFailedAndIncompleteAfterImageOutputNeverReturnPartialSuccess() async throws {
        for (type, code) in [("failed", "responses_stream_failed"), ("incomplete", "responses_stream_incomplete")] {
            let terminal = #"{"type":"response.\#(type)","sequence_number":9,"response":{"id":"resp-failed","status":"\#(type)","error":{"code":"image_rejected","type":"invalid_request_error","message":"Provider explanation"},"incomplete_details":{"reason":"max_output_tokens"}}}"#
            await TestURLProtocol.enqueue(.init(headers: ["x-request-id": "provider-request"],
                body: imageSSE(imageDone(imageItem(status: "generating")), terminal)))
            let error = try await failure()
            XCTAssertEqual(error.code, code)
            XCTAssertEqual(error.message, "Provider explanation")
            XCTAssertEqual(error.http?.providerCode, "image_rejected")
            XCTAssertEqual(error.http?.providerType, "invalid_request_error")
            XCTAssertEqual(error.http?.requestID, "provider-request")
            XCTAssertNotNil(error.interruption?.clientRequestID)
            XCTAssertEqual(error.interruption?.requestID, "provider-request")
            XCTAssertEqual(error.interruption?.responseID, "resp-failed")
            XCTAssertEqual(error.interruption?.lastSequenceNumber, 9)
            XCTAssertEqual(error.interruption?.hasToolActivity, true)
            XCTAssertEqual(error.interruption?.providerCompleted, false)
        }
    }

    func testTopLevelStreamErrorsPreserveProviderFields() async throws {
        for terminal in [
            #"{"type":"error","code":"server_error","message":"Try again"}"#,
            #"{"type":"error","error":{"code":"server_error","type":"provider_error","message":"Try again"}}"#
        ] {
            await TestURLProtocol.enqueue(.init(headers: ["request-id": "request-1"], body: imageSSE(terminal)))
            let error = try await failure()
            XCTAssertEqual(error.code, "responses_stream_failed")
            XCTAssertEqual(error.http?.providerCode, "server_error")
            XCTAssertEqual(error.http?.requestID, "request-1")
            XCTAssertEqual(error.message, "Try again")
        }
    }

    func testEOFDoneSentinelAndPlainJSONCannotCompleteImages() async throws {
        for data in [
            imageSSE(imageDone(imageItem())),
            imageSSE(imageDone(imageItem()), "[DONE]"),
            Data(#"{"output":[{"type":"image_generation_call","id":"image","result":"AQID"}]}"#.utf8)
        ] {
            await TestURLProtocol.enqueue(.init(headers: ["x-request-id": "truncated"], body: data))
            let error = try await failure()
            XCTAssertTrue(["responses_stream_disconnected", "image_generation_invalid_response"].contains(error.code))
            XCTAssertEqual(error.http?.requestID, "truncated")
        }
    }

    func testMissingInvalidOrUnfinishedTerminalOutputIsRejected() async throws {
        for (items, code) in [
            ([#"{"type":"message","role":"assistant","content":[]}"#], "image_generation_missing_output"),
            ([imageItem(result: "bad base64")], "image_generation_missing_output"),
            ([imageItem(), imageItem(id: "unfinished", status: "in_progress")], "image_generation_invalid_response"),
            ([imageItem(status: "failed")], "image_generation_invalid_response")
        ] as [([String], String)] {
            await TestURLProtocol.enqueue(.init(body: imageSSE(imageDone(imageItem()), imageCompleted(items))))
            let error = try await failure()
            XCTAssertEqual(error.code, code)
        }
    }

    func testCompletedEnvelopeWithIncompleteStatusCannotSucceed() async throws {
        await TestURLProtocol.enqueue(.init(body: imageSSE(imageDone(imageItem()),
            #"{"type":"response.completed","response":{"id":"resp","status":"incomplete","incomplete_details":{"reason":"max_output_tokens"}}}"#)))
        let error = try await failure()
        XCTAssertEqual(error.code, "responses_stream_incomplete")
        XCTAssertTrue(error.message.contains("max_output_tokens"))
    }

    func testTextOnlyCompletionReportsTypesWithoutLeakingContentsOrRetrying() async throws {
        let message = #"{"type":"message","role":"assistant","content":[{"type":"output_text","text":"PRIVATE_RESPONSE_TEXT"}]}"#
        let unknown = #"{"type":"PRIVATE_UNKNOWN_TYPE","content":"PRIVATE_PAYLOAD"}"#
        await TestURLProtocol.enqueue(.init(body: imageSSE(imageDone(message), imageCompleted([message, unknown]))))
        await TestURLProtocol.enqueue(.init(body: imageSSE(imageCompleted([imageItem()]))))
        let error = try await failure()
        XCTAssertEqual(error.code, "image_generation_missing_output")
        XCTAssertTrue(error.message.contains("Terminal output types: [message, unrecognized]"))
        XCTAssertTrue(error.message.contains("Stream output types: [message]"))
        XCTAssertFalse(error.message.contains("PRIVATE"))
        XCTAssertEqual(error.interruption?.providerCompleted, true)
        XCTAssertNil(error.retry)
    }

    func testPreviewAndMalformedCompletionCannotReturnAnImage() async throws {
        for terminal in [
            #"{"type":"response.completed"}"#,
            #"{"type":"response.completed","response":{"status":"completed","error":{"code":"failed"}}}"#,
            #"{"type":"response.completed","response":{"status":"completed","incomplete_details":{"reason":"max_output_tokens"}}}"#
        ] {
            await TestURLProtocol.enqueue(.init(body: imageSSE(imageDone(imageItem()), terminal)))
            let error = try await failure()
            XCTAssertTrue(["responses_stream_failed", "responses_stream_incomplete"].contains(error.code))
        }
        await TestURLProtocol.enqueue(.init(body: imageSSE(
            #"{"type":"response.image_generation_call.partial_image","partial_image_b64":"AQID","item_id":"image"}"#,
            imageCompleted([]))))
        let error = try await failure()
        XCTAssertEqual(error.code, "image_generation_missing_output")
    }

    func testUnauthorizedAndQuotaErrorsRemainStructuredWithoutRetry() async throws {
        for (status, code) in [(401, "unauthorized"), (429, "quota_exceeded")] {
            await TestURLProtocol.enqueue(.init(statusCode: status,
                headers: ["x-request-id": "request-1"],
                body: Data(#"{"error":{"code":"insufficient_quota","type":"insufficient_quota","message":"Explanation"}}"#.utf8)))
            await TestURLProtocol.enqueue(.init(body: imageSSE(imageCompleted([imageItem()]))))
            let error = try await failure()
            XCTAssertEqual(error.code, code)
            XCTAssertEqual(error.http?.requestID, "request-1")
            XCTAssertEqual(error.http?.providerCode, "insufficient_quota")
            await TestURLProtocol.reset()
        }
    }

    func testHTTPErrorKeepsExplanationAndCorrelationWithoutRawPayloadOrRetry() async throws {
        for status in [400, 429, 500] {
            await TestURLProtocol.enqueue(.init(statusCode: status,
                headers: ["x-request-id": "provider-400", "Retry-After": "30"],
                body: Data(#"{"error":{"code":"unsupported_parameter","type":"invalid_request_error","message":"stream must be true"},"input":"PRIVATE_PHOTO","authorization":"SECRET_TOKEN"}"#.utf8)))
            // A retry would consume this success and fail the assertions below.
            await TestURLProtocol.enqueue(.init(body: imageSSE(imageCompleted([imageItem()]))))
            let error = try await failure()
            XCTAssertEqual(error.code, "image_generation_http_status_\(status)")
            XCTAssertEqual(error.http?.providerCode, "unsupported_parameter")
            XCTAssertEqual(error.http?.providerType, "invalid_request_error")
            XCTAssertEqual(error.http?.requestID, "provider-400")
            XCTAssertEqual(error.http?.retryAfter, 30)
            XCTAssertEqual(error.message, "stream must be true")
            XCTAssertNotNil(error.interruption?.clientRequestID)
            XCTAssertNil(error.retry)
            await TestURLProtocol.reset()
        }
    }

    func testTransportFailureDoesNotRetry() async throws {
        await TestURLProtocol.enqueue(.init(body: Data(), error: URLError(.networkConnectionLost)))
        await TestURLProtocol.enqueue(.init(body: imageSSE(imageCompleted([imageItem()]))))
        let error = try await failure()
        XCTAssertEqual(error.interruption?.transportErrorCode, URLError.networkConnectionLost.rawValue)
        XCTAssertEqual(error.interruption?.outcome, .disconnected)
    }

    private func generate() async throws -> [AgentGeneratedImage] {
        try await AgentImageGenerationClient(configuration: .init(), urlSession: makeTestURLSession()).generate(prompt: "Draw", session: demoSession())
    }

    private func failure() async throws -> AgentRuntimeError {
        do {
            _ = try await generate()
            XCTFail("Expected image generation failure")
            throw NSError(domain: "test", code: 1)
        } catch {
            return try XCTUnwrap(error as? AgentRuntimeError)
        }
    }
}

func imageRequestJSON(_ request: URLRequest) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requestBodyData(for: request))) as? [String: Any])
}

func imageItem(id: String = "image", status: String = "completed", result: String = "AQID", format: String? = nil) -> String {
    let formatField = format.map { ",\"output_format\":\"\($0)\"" } ?? ""
    return #"{"type":"image_generation_call","id":"\#(id)","status":"\#(status)","result":"\#(result)"\#(formatField)}"#
}

func imageDone(_ item: String) -> String {
    #"{"type":"response.output_item.done","output_index":0,"item":\#(item)}"#
}

func imageCompleted(_ items: [String]) -> String {
    #"{"type":"response.completed","response":{"id":"response-1","status":"completed","output":[\#(items.joined(separator: ","))]}}"#
}

func imageSSE(_ events: String...) -> Data {
    Data(events.map { "data: \($0)\n\n" }.joined().utf8)
}
