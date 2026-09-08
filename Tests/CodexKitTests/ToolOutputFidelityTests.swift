@testable import CodexKit
import CodexKitRealm
import CodexKitSQLite
import ImageIO
import UniformTypeIdentifiers
import XCTest

final class ToolOutputFidelityTests: XCTestCase {
    override func setUp() async throws { await TestURLProtocol.reset() }
    override func tearDown() async throws { await TestURLProtocol.reset() }

    func testAllTextBlocksReachProviderRequestsAndFallbackReplies() async throws {
        await TestURLProtocol.enqueue(.init(body: Data("""
        data: {"type":"response.output_item.done","item":{"type":"function_call","name":"lookup","call_id":"call","arguments":"{}"}}

        data: {"type":"response.completed","response":{"id":"first"}}

        """.utf8)))
        await TestURLProtocol.enqueue(.init(body: Data("data: {\"type\":\"response.completed\",\"response\":{\"id\":\"second\"}}\n\n".utf8), inspect: { request in
            let json = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(requestBodyData(for: request)))
            let output = json.objectValue?["input"]?.arrayValue?.first { $0.objectValue?["type"]?.stringValue == "function_call_output" }
            XCTAssertEqual(output?.objectValue?["output"]?.stringValue, "First result\n\nSecond result")
        }))
        let backend = CodexResponsesBackend(urlSession: makeTestURLSession())
        let stream = try await backend.beginTurn(thread: .init(id: "thread"), history: [], message: Request(text: "Go"),
            instructions: "", responseFormat: nil, streamedStructuredOutput: nil,
            tools: [.init(name: "lookup", description: "Lookup", inputSchema: .object([:]))], session: demoSession())
        var reply: String?
        for try await event in stream.events {
            if case let .toolCallRequested(invocation) = event {
                try await stream.submitToolResult(.init(invocationID: invocation.id, toolName: invocation.toolName,
                    success: true, content: [.text("First result"), .text("Second result")]), for: invocation.id)
            }
            if case let .assistantMessageCompleted(message) = event { reply = message.text }
        }
        XCTAssertEqual(reply, "First result\n\nSecond result")
    }

    func testContextRetainsAllToolTextWhilePrimaryPreviewStaysConcise() async throws {
        let runtime = try AgentRuntime(configuration: .init(sessionProvider: DesignReadOnlyProvider(), backend: DesignBackend(),
            approvalPresenter: AutoApprovalPresenter(), stateStore: InMemoryRuntimeStateStore()))
        let thread = try await runtime.createThread()
        let result = ToolResultEnvelope(invocationID: "call", toolName: "lookup", success: true,
            content: [.text("First result"), .text("Second result")])
        await runtime.appendEffectiveToolInteraction(invocation: .init(id: "call", threadID: thread.id,
            turnID: "turn", toolName: "lookup", arguments: .null), result: result)
        let history = await runtime.effectiveHistory(for: thread.id)
        XCTAssertTrue(history.last?.text.contains("First result\n\nSecond result") == true)
        XCTAssertEqual(result.primaryText, "First result")
    }

    func testTextRenderingPreservesImagesAndEmptyResultFallbacks() {
        let adapter = CodexResponsesToolOutputAdapter(urlSession: makeTestURLSession())
        let result = ToolResultEnvelope(invocationID: "call", toolName: "lookup", success: true,
            content: [.text(""), .text("First"), .image(URL(string: "https://example.com/image")!), .text("Second")])
        XCTAssertEqual(adapter.text(from: result), "First\n\nSecond\n\nImage URLs:\nhttps://example.com/image")
        XCTAssertEqual(adapter.text(from: .init(invocationID: "call", toolName: "lookup", success: false,
            errorMessage: "Failure")), "Failure")
        XCTAssertEqual(adapter.text(from: .init(invocationID: "call", toolName: "lookup", success: true)), "Tool execution completed.")
    }

    func testReopenedDatabaseContextRetainsEveryToolTextBlock() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        for adapter in ["sqlite", "realm"] {
            let url = directory.appendingPathComponent(adapter)
            let openStore: () throws -> any RuntimeStateStoring = {
                adapter == "sqlite" ? try SQLiteRuntimeStateStore(url: url) : try RealmRuntimeStateStore(url: url)
            }
            let thread = AgentThread(id: "thread")
            let invocation = ToolInvocation(id: "call", threadID: thread.id, turnID: "turn", toolName: "lookup", arguments: .null)
            let result = ToolResultEnvelope(invocationID: invocation.id, toolName: invocation.toolName, success: true,
                content: [.text("First result"), .text("Second result")])
            let items: [AgentHistoryItem] = [
                .message(.init(threadID: thread.id, role: .user, text: "Look up")),
                .toolCall(.init(invocation: invocation)),
                .toolResult(.init(threadID: thread.id, turnID: invocation.turnID, result: result)),
                .message(.init(threadID: thread.id, role: .assistant, text: "Done")),
            ]
            let store = try openStore()
            try await store.saveState(.init(threads: [thread], historyByThread: [thread.id:
                items.enumerated().map { .init(sequenceNumber: $0.offset + 1, createdAt: Date(), item: $0.element) }]))
            let reopened = try openStore()
            let activation = try await reopened.loadThreadActivationState(id: thread.id, policy: .init())
            let tool = try XCTUnwrap(activation.effectiveMessages.first { $0.role == .tool })
            XCTAssertEqual(tool.text, "Tool lookup completed: First result\n\nSecond result", adapter)
            XCTAssertEqual(tool.toolInteraction?.result, result)
        }
    }

    func testRemoteImagesRejectHTTPFailuresHTMLAndTruncatedData() async throws {
        let png = try imageData(type: .png)
        let cases: [(Int, String, Data)] = [
            (404, "image/png", png), (503, "image/png", png),
            (200, "text/html", Data("<html>Not an image</html>".utf8)),
            (200, "image/png", Data("<html>Not an image</html>".utf8)),
            (200, "image/png", Data(png.prefix(24))),
        ]
        for (status, mime, bytes) in cases {
            await TestURLProtocol.enqueue(.init(statusCode: status, headers: ["Content-Type": mime], body: bytes))
            let images = await downloadedImages()
            XCTAssertTrue(images.isEmpty, "Invalid image accepted for status \(status), MIME \(mime)")
        }
    }

    func testValidRemoteImagesUseDetectedTypeAndPreserveOriginalBytes() async throws {
        for type in [UTType.png, .jpeg, .gif] {
            let data = try imageData(type: type)
            await TestURLProtocol.enqueue(.init(body: data))
            let images = await downloadedImages()
            XCTAssertEqual(images.count, 1)
            XCTAssertEqual(images.first?.mimeType, type.preferredMIMEType)
            XCTAssertEqual(images.first?.data, data)
        }
        let png = try imageData(type: .png)
        await TestURLProtocol.enqueue(.init(headers: ["Content-Type": "text/plain"], body: png))
        let images = await downloadedImages()
        XCTAssertEqual(images.first?.mimeType, "image/png", "Actual image bytes determine the media type")
    }

    func testOversizedRemoteImageIsRejectedFromHeaders() async throws {
        await TestURLProtocol.enqueue(.init(headers: ["Content-Length": "\(AgentStoreLimits.maximumImageByteCount + 1)"],
            body: try imageData(type: .png)))
        let images = await downloadedImages()
        XCTAssertTrue(images.isEmpty)
    }

    func testCancelledImageLoadDoesNotStartADownload() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await CodexResponsesToolOutputAdapter(urlSession: makeTestURLSession()).images(from:
                .init(invocationID: "call", toolName: "lookup", success: true,
                    content: [.image(URL(string: "https://example.com/image")!)]))
        }
        let images = await task.value
        XCTAssertTrue(images.isEmpty)
    }

    private func downloadedImages() async -> [AgentImageAttachment] {
        await CodexResponsesToolOutputAdapter(urlSession: makeTestURLSession()).images(from:
            .init(invocationID: "call", toolName: "lookup", success: true,
                content: [.image(URL(string: "https://example.com/download.jpeg")!)]))
    }

    private func imageData(type: UTType) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
