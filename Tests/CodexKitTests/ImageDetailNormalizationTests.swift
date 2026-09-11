@testable import CodexKit
import CodexKitSQLite
import CodexKitRealm
import XCTest

final class ImageDetailNormalizationTests: XCTestCase {
    override func setUp() async throws { await TestURLProtocol.reset() }
    override func tearDown() async throws { await TestURLProtocol.reset() }

    func testNormalizationCoversMessageAndToolImagesWithoutChangingOtherData() throws {
        for type in ["message", "function_call_output", "custom_tool_call_output"] {
            let key = type == "message" ? "content" : "output"
            let content = [nil, "auto", "low", "high", "original"].map { detail -> JSONValue in
                var image: [String: JSONValue] = ["type": .string("input_image"), "image_url": .string("https://example.com/image.png")]
                if let detail { image["detail"] = .string(detail) }
                return .object(image)
            }
            let input = [JSONValue.object(["type": .string(type), key: .array(content), "detail": .string("original")])]
            let normalized = CodexResponsesImageDetail.normalize(input, supportsOriginal: false)
            let details = normalized.first?.objectValue?[key]?.arrayValue?.map { $0.objectValue?["detail"]?.stringValue }
            XCTAssertEqual(details, [nil, "auto", "low", "high", "high"])
            XCTAssertEqual(normalized.first?.objectValue?["detail"], .string("original"))
            XCTAssertEqual(input.first?.objectValue?[key]?.arrayValue?.last?.objectValue?["detail"], .string("original"))
            XCTAssertEqual(CodexResponsesImageDetail.normalize(input, supportsOriginal: true), input)
        }
        let arbitrary: JSONValue = .object(["type": .string("reasoning"), "content": .array([
            .object(["type": .string("input_image"), "detail": .string("original")])])])
        XCTAssertEqual(CodexResponsesImageDetail.normalize([arbitrary], supportsOriginal: false), [arbitrary])
    }

    func testModelSwitchUsesRemoteCapabilitiesAndPreservesProviderHistory() async throws {
        let backend = CodexResponsesBackend(urlSession: makeTestURLSession())
        await TestURLProtocol.enqueue(.init(body: Data(#"{"models":[{"slug":"capable","supports_image_detail_original":true},{"slug":"limited","supports_image_detail_original":false},{"slug":"gpt-5.5","supports_image_detail_original":false}]}"#.utf8)))
        let catalog = try await backend.listModels(session: demoSession(), policy: .refresh)
        XCTAssertEqual(catalog.models.map(\.supportsImageDetailOriginal), [true, false, false])
        let image = AgentImageAttachment.png(Data([137, 80, 78, 71]), detail: .original)
        let message = AgentMessage(threadID: "thread", role: .user, text: "Image", images: [image])
        var context: AgentProviderContext?
        for (model, detail) in [("capable", "original"), ("limited", "high"), ("gpt-5.5", "high"), ("unknown", "high"), ("capable", "original")] {
            await TestURLProtocol.enqueue(.init(body: completed, inspect: { request in
                let body = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(requestBodyData(for: request)))
                let first = body.objectValue?["input"]?.arrayValue?.first
                XCTAssertEqual(first?.objectValue?["content"]?.arrayValue?.last?.objectValue?["detail"], .string(detail))
            }))
            let turn = try await backend.beginTurn(thread: .init(id: "thread", configuration: .init(model: CodexModel(rawValue: model))),
                history: [message], providerContext: context, message: Request(text: "Next"), instructions: "",
                responseFormat: nil, streamedStructuredOutput: nil, tools: [], session: demoSession())
            for try await event in turn.events {
                if case let .providerContextUpdated(_, updated) = event { context = updated }
            }
            XCTAssertEqual(context?.payload.objectValue?["items"]?.arrayValue?.first?.objectValue?["content"]?.arrayValue?.last?.objectValue?["detail"], .string("original"))
        }
        XCTAssertEqual(image.detail, .original)
        var otherAccount = demoSession()
        otherAccount.account.id = "other"
        let otherSupport = await backend.supportsImageDetailOriginal(for: "capable", session: otherAccount)
        XCTAssertFalse(otherSupport)
    }

    func testCompactionNormalizesOnlyRequestCopy() async throws {
        let image = AgentImageAttachment.png(Data([1, 2, 3]), detail: .original)
        let message = AgentMessage(threadID: "thread", role: .user, text: "Keep", images: [image])
        await TestURLProtocol.enqueue(.init(body: streamedCompactionReply(), inspect: { request in
            let body = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(requestBodyData(for: request)))
            XCTAssertEqual(body.objectValue?["input"]?.arrayValue?.first?.objectValue?["content"]?.arrayValue?.last?.objectValue?["detail"], .string("high"))
        }))
        let compacted = try await CodexResponsesBackend(urlSession: makeTestURLSession()).compactContext(
            thread: .init(id: "thread", configuration: .init(model: CodexModel(rawValue: "unknown"))), effectiveHistory: [message],
            instructions: "", tools: [], session: demoSession())
        XCTAssertEqual(compacted.effectiveMessages.first?.images.first?.detail, .original)
        XCTAssertEqual(compacted.providerContext?.payload.objectValue?["items"]?.arrayValue?.first?.objectValue?["content"]?.arrayValue?.last?.objectValue?["detail"], .string("original"))
    }

    func testDetailSurvivesAttachmentPersistenceAndLegacyDecoding() async throws {
        let image = AgentImageAttachment.png(Data([1, 2, 3]), detail: .original)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for adapter in ["file", "sqlite", "realm"] {
            let url = root.appendingPathComponent(adapter)
            let open: () throws -> any RuntimeStateStoring = {
                switch adapter {
                case "sqlite": return try SQLiteRuntimeStateStore(url: url)
                case "realm": return try RealmRuntimeStateStore(url: url)
                default: return FileRuntimeStateStore(url: url)
                }
            }
            let store = try open()
            let message = AgentMessage(threadID: "thread", role: .user, text: "Image", images: [image])
            try await store.saveState(.init(threads: [.init(id: "thread")], messagesByThread: ["thread": [message]]))
            let reopened = try open()
            let state = try await reopened.loadState()
            XCTAssertEqual(state.messagesByThread["thread"]?.first?.images.first, image)
        }
        let legacy = Data(#"{"id":"old","mimeType":"image/png","data":"AQID"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(AgentImageAttachment.self, from: legacy).detail)
        let legacyReference = Data(#"{"id":"old","mimeType":"image/png","storageKey":"blob"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(PersistedImageAttachment.self, from: legacyReference).detail)
    }

    func testLegacyModelMetadataDecodesWithConservativeCapabilities() throws {
        let info = try XCTUnwrap(CodexModel.gpt52.info)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(info)) as? [String: Any])
        object.removeValue(forKey: "supportsImageDetailOriginal")
        let decoded = try JSONDecoder().decode(CodexModelInfo.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertFalse(decoded.supportsImageDetailOriginal)
        XCTAssertEqual(decoded, info)
    }

    func testImageEditingNormalizesOriginalForReceivingModel() async throws {
        let image = AgentImageAttachment.png(Data([1, 2, 3]), detail: .original)
        for (model, expected) in [("gpt-5.5", "original"), ("unknown", "high")] {
            await TestURLProtocol.enqueue(.init(body: Data(#"{"output":[{"type":"image_generation_call","id":"image","result":"AQID"}]}"#.utf8), inspect: { request in
                let body = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(requestBodyData(for: request)))
                XCTAssertEqual(body.objectValue?["input"]?.arrayValue?.first?.objectValue?["content"]?.arrayValue?.last?.objectValue?["detail"], .string(expected))
            }))
            let client = AgentImageGenerationClient(configuration: .init(model: model), urlSession: makeTestURLSession())
            _ = try await client.edit(images: [image], prompt: "Edit", session: demoSession())
        }
        XCTAssertEqual(image.detail, .original)
    }

    private var completed: Data {
        Data("data: {\"type\":\"response.completed\",\"response\":{\"id\":\"done\"}}\n\n".utf8)
    }
}
