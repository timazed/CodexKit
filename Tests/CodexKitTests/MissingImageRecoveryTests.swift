@testable import CodexKit
import XCTest

final class MissingImageRecoveryTests: XCTestCase {
    override func setUp() async throws { await TestURLProtocol.reset() }
    override func tearDown() async throws { await TestURLProtocol.reset() }

    func testPlaceholderPreservesTextAvailableImagesAndOriginalReferences() throws {
        let missing = AgentImageAttachment.png(Data("missing".utf8))
        let available = AgentImageAttachment.png(Data("available".utf8))
        let original = [WorkingHistoryItem.userMessage(.init(threadID: "t", role: .user,
            text: "Keep this text", images: [missing, available, missing])).jsonValue]
        let stored = try CodexResponsesImageReferences.externalize(original)
        let restored = try CodexResponsesImageReferences.restore(stored, using: [available], missingImagePolicy: .placeholder)
        let content = try XCTUnwrap(restored.first?.objectValue?["content"]?.arrayValue)
        XCTAssertEqual(content.filter { $0.objectValue?["text"] == .string("[image unavailable]") }.count, 2)
        XCTAssertTrue(content.contains { $0.objectValue?["text"] == .string("Keep this text") })
        XCTAssertTrue(content.contains { $0.objectValue?["image_url"] == .string(available.dataURLString) })
        XCTAssertEqual(try CodexResponsesImageReferences.restore(stored, using: [missing, available]), original)
        XCTAssertThrowsError(try CodexResponsesImageReferences.restore(stored, using: [available]))
    }

    func testUnknownReferenceLocationsStillFailInsteadOfRewritingArbitraryText() throws {
        let values: [JSONValue] = [.string("codexkit-image-ref:data-url:missing")]
        XCTAssertThrowsError(try CodexResponsesImageReferences.restore(values, using: [], missingImagePolicy: .placeholder))
    }

    func testGeneratedImageIsReplacedWithValidAssistantContent() throws {
        let original: [JSONValue] = [.object(["type": .string("image_generation_call"),
            "result": .string("codexkit-image-ref:base64:missing")])]
        let output = try CodexResponsesImageReferences.restore(original, using: [], missingImagePolicy: .placeholder)
        XCTAssertEqual(output.first?.objectValue?["role"], .string("assistant"))
        XCTAssertNil(output.first?.objectValue?["result"])
    }

    func testGenerationUsesRequestOnlyPlaceholderAndCanRecoverImageNextTurn() async throws {
        let image = AgentImageAttachment.png(Data("recoverable".utf8))
        let items = try CodexResponsesImageReferences.externalize([
            WorkingHistoryItem.userMessage(.init(threadID: "t", role: .user, text: "original", images: [image])).jsonValue])
        let context = CodexResponsesProviderState(items: items).agentProviderContext
        var configuration = CodexResponsesBackendConfiguration()
        configuration.missingImagePolicy = .placeholder
        let backend = CodexResponsesBackend(configuration: configuration, urlSession: makeTestURLSession())
        await TestURLProtocol.enqueue(.init(body: completed, inspect: { request in
            XCTAssertTrue(String(decoding: try requestBodyData(for: request) ?? Data(), as: UTF8.self).contains("[image unavailable]"))
        }))
        var updated: AgentProviderContext?
        let stream = try await begin(backend, context: context, history: [])
        for try await event in stream.events {
            if case let .providerContextUpdated(_, value) = event { updated = value }
        }
        XCTAssertEqual(CodexResponsesProviderState(context: updated)?.items.first, items.first)
        await TestURLProtocol.enqueue(.init(body: completed, inspect: { request in
            let body = String(decoding: try requestBodyData(for: request) ?? Data(), as: UTF8.self)
            XCTAssertFalse(body.contains("[image unavailable]"))
            XCTAssertTrue(body.contains(image.data.base64EncodedString()))
        }))
        let next = try await begin(backend, context: updated, history: [.init(threadID: "t", role: .user, text: "original", images: [image])])
        for try await _ in next.events {}
    }

    func testCompactionAlsoUsesExplicitMissingImagePlaceholder() async throws {
        let image = AgentImageAttachment.png(Data("missing".utf8))
        let items = try CodexResponsesImageReferences.externalize([
            WorkingHistoryItem.userMessage(.init(threadID: "t", role: .user, text: "Keep", images: [image])).jsonValue])
        var configuration = CodexResponsesBackendConfiguration()
        configuration.missingImagePolicy = .placeholder
        let backend = CodexResponsesBackend(configuration: configuration, urlSession: makeTestURLSession())
        await TestURLProtocol.enqueue(.init(body: streamedCompactionReply(), inspect: { request in
            XCTAssertTrue(String(decoding: try requestBodyData(for: request) ?? Data(), as: UTF8.self).contains("[image unavailable]"))
        }))
        let context = CodexResponsesProviderState(items: items).agentProviderContext
        let result = try await backend.compactContext(thread: .init(id: "t"), effectiveHistory: [],
            providerContext: context, instructions: "", tools: [], session: demoSession())
        XCTAssertTrue(result.effectiveMessages.first?.text.contains("[image unavailable]") == true)
        XCTAssertEqual(CodexResponsesProviderState(context: context)?.items, items)
    }

    private var completed: Data { Data("data: {\"type\":\"response.completed\",\"response\":{\"id\":\"done\"}}\n\n".utf8) }
    private func begin(_ backend: CodexResponsesBackend, context: AgentProviderContext?, history: [AgentMessage]) async throws -> AgentTurnStream {
        try await backend.beginTurn(thread: .init(id: "t"), history: history, providerContext: context,
            message: Request(text: "Next"), instructions: "", responseFormat: nil,
            streamedStructuredOutput: nil, tools: [], session: demoSession())
    }
}
