@testable import CodexKit
import XCTest

final class CodexCurrentModelSupportTests: XCTestCase {
    // Model catalog capability snapshot as of 30 September 2026.
    // Keep upstream data independent of the Swift catalog to detect metadata drift.
    private let upstreamCatalog = #"""
    {"models":[
        {"slug":"gpt-6-astra","display_name":"GPT-6-Astra","description":"Frontier intelligence for the most demanding work.","default_reasoning_level":"low","supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"high"},{"effort":"xhigh"},{"effort":"max"},{"effort":"ultra"}],"context_window":272000,"input_modalities":["text","image"],"visibility":"list","supports_image_detail_original":true},
        {"slug":"gpt-6.1-sol","display_name":"GPT-6.1-Sol","description":"Latest workhorse model for coding and everyday work.","default_reasoning_level":"low","supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"high"},{"effort":"xhigh"},{"effort":"max"},{"effort":"ultra"}],"context_window":272000,"input_modalities":["text","image"],"visibility":"list","supports_image_detail_original":true},
        {"slug":"gpt-6-sol","display_name":"GPT-6-Sol","description":"Previous generation workhorse model.","default_reasoning_level":"medium","supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"high"},{"effort":"xhigh"},{"effort":"max"},{"effort":"ultra"}],"context_window":272000,"input_modalities":["text","image"],"visibility":"list","supports_image_detail_original":true},
        {"slug":"gpt-6-luna","display_name":"GPT-6-Luna","description":"Fast and affordable model for easier tasks.","default_reasoning_level":"medium","supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"high"},{"effort":"xhigh"},{"effort":"max"}],"context_window":272000,"input_modalities":["text","image"],"visibility":"list","supports_image_detail_original":true},
        {"slug":"gpt-5.6-sol","display_name":"GPT-5.6-Sol","description":"Older generation workhorse model.","default_reasoning_level":"low","supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"high"},{"effort":"xhigh"},{"effort":"max"},{"effort":"ultra"}],"context_window":272000,"input_modalities":["text","image"],"visibility":"list","supports_image_detail_original":true},
        {"slug":"gpt-5.6-terra","display_name":"GPT-5.6-Terra","description":"Older balanced model for straightforward work.","default_reasoning_level":"medium","supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"high"},{"effort":"xhigh"},{"effort":"max"},{"effort":"ultra"}],"context_window":272000,"input_modalities":["text","image"],"visibility":"list","supports_image_detail_original":true},
        {"slug":"gpt-5.6-luna","display_name":"GPT-5.6-Luna","description":"Older fast and efficient model.","default_reasoning_level":"medium","supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"high"},{"effort":"xhigh"},{"effort":"max"}],"context_window":272000,"input_modalities":["text","image"],"visibility":"list","supports_image_detail_original":true},
        {"slug":"gpt-daybreak-blue-latest","display_name":"Daybreak Blue","description":"Latest frontier agentic coding model for broad defensive cybersecurity work.","default_reasoning_level":"low","supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"high"},{"effort":"xhigh"},{"effort":"max"},{"effort":"ultra"}],"context_window":272000,"input_modalities":["text","image"],"visibility":"hide","supports_image_detail_original":true},
        {"slug":"gpt-daybreak-red-latest","display_name":"Daybreak Red","description":"Cyber-permissive variant of our latest frontier agentic coding model for advanced, authorized cybersecurity research.","default_reasoning_level":"medium","supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"high"},{"effort":"xhigh"},{"effort":"max"},{"effort":"ultra"}],"context_window":372000,"input_modalities":["text","image"],"visibility":"hide","supports_image_detail_original":true},
        {"slug":"gpt-5.5","display_name":"GPT-5.5","description":"Legacy coding model.","default_reasoning_level":"medium","supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"high"},{"effort":"xhigh"}],"context_window":272000,"input_modalities":["text","image"],"visibility":"list","supports_image_detail_original":true},
        {"slug":"codex-auto-review","display_name":"Codex Auto Review","description":"Automatic approval review model for Codex.","default_reasoning_level":"medium","supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"high"},{"effort":"xhigh"},{"effort":"max"}],"context_window":272000,"input_modalities":["text","image"],"visibility":"hide","supports_image_detail_original":true}
    ]}
    """#

    func testBundledCapabilitiesAndPickerMatchCurrentUpstreamCatalog() throws {
        let upstream = try CodexResponsesBackend.decodeModels(Data(upstreamCatalog.utf8))
        let bundled = CodexModelCatalogSnapshot.bundled
        XCTAssertEqual(bundled.visibleModels.map(\.model), upstream.filter { !$0.hidden }.map(\.model))
        for remote in upstream {
            let info = try XCTUnwrap(remote.model.info, remote.id)
            XCTAssertEqual(info.displayName, remote.displayName, remote.id)
            XCTAssertEqual(info.summary, remote.summary, remote.id)
            XCTAssertEqual(info.defaultReasoningEffort, remote.defaultReasoningEffort, remote.id)
            XCTAssertEqual(info.supportedReasoningEfforts, remote.supportedReasoningEfforts, remote.id)
            XCTAssertEqual(info.contextWindowTokenCount, remote.contextWindowTokenCount, remote.id)
            XCTAssertEqual(info.inputModalities, remote.inputModalities, remote.id)
            XCTAssertEqual(info.supportsImageDetailOriginal, remote.supportsImageDetailOriginal, remote.id)
            XCTAssertEqual(bundled.models.first { $0.model == remote.model }?.hidden, remote.hidden, remote.id)
            XCTAssertEqual(CodexResponsesBackendConfiguration(model: remote.model).reasoningEffort,
                           remote.defaultReasoningEffort, remote.id)
            XCTAssertEqual(AgentThreadConfiguration(model: remote.model).reasoningEffort,
                           remote.defaultReasoningEffort, remote.id)
        }
    }

    func testSelectionValidatesNewModelEffortsAndBundledContextLimits() async throws {
        let backend = CodexResponsesBackend()
        let session = ChatGPTSession(accessToken: "test-token", refreshToken: "test-refresh",
            account: .init(id: "test-account", email: "test@example.com", plan: .plus))
        let thread = AgentThread(id: "test")
        for model in [CodexModel.gpt61Sol, .gpt6Sol, .gpt6Luna, .daybreakBlueLatest, .daybreakRedLatest] {
            let info = try XCTUnwrap(model.info)
            var request = Request(text: "Hello")
            request.modelOverride = .init(model: model)
            request.modelRequirements = .init(minimumContextWindowTokenCount: info.contextWindowTokenCount)
            let selection = try await backend.prepareModelSelection(for: request, in: thread,
                responseFormat: nil, session: session)
            XCTAssertEqual(selection.configuration.codexModel, model)
            XCTAssertEqual(selection.configuration.reasoningEffort, info.defaultReasoningEffort)
            request.modelRequirements = .init(minimumContextWindowTokenCount: info.contextWindowTokenCount + 1)
            do {
                _ = try await backend.prepareModelSelection(for: request, in: thread,
                    responseFormat: nil, session: session)
                XCTFail("Must reject an insufficient context window for \(model)")
            } catch { XCTAssertEqual(error as? AgentModelSelectionError, .configurationUnavailable) }
        }
        var request = Request(text: "Hello")
        request.modelOverride = .init(model: .gpt6Luna, reasoningEffort: .ultra)
        do {
            _ = try await backend.prepareModelSelection(for: request, in: thread,
                responseFormat: nil, session: session)
            XCTFail("Luna does not support ultra")
        } catch { XCTAssertEqual(error as? AgentModelSelectionError, .configurationUnavailable) }
    }

    func testNewModelsPreserveIdentifiersReasoningAndOriginalImagesOnWire() throws {
        let session = ChatGPTSession(accessToken: "test-token", refreshToken: "test-refresh",
            account: .init(id: "test-account", email: "test@example.com", plan: .plus))
        let input: [JSONValue] = [.object(["type": .string("message"), "role": .string("user"),
            "content": .array([.object(["type": .string("input_image"),
                "image_url": .string("data:image/png;base64,AQID"), "detail": .string("original")])])])]
        for model in [CodexModel.gpt61Sol, .gpt6Sol, .gpt6Luna, .daybreakBlueLatest, .daybreakRedLatest] {
            let info = try XCTUnwrap(model.info)
            let encoded = try JSONEncoder().encode(model)
            XCTAssertEqual(try JSONDecoder().decode(CodexModel.self, from: encoded), model)
            let factory = CodexResponsesRequestFactory(configuration: .init(model: model), encoder: JSONEncoder())
            for effort in info.supportedReasoningEfforts {
                let request = try factory.buildURLRequest(model: model.rawValue, reasoning: .init(effort: effort),
                    instructions: "Help", input: input, tools: [], requestID: "test", session: session)
                let body = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(request.httpBody))
                XCTAssertEqual(body.objectValue?["model"], .string(model.rawValue))
                XCTAssertEqual(body.objectValue?["reasoning"]?.objectValue?["effort"],
                               .string(effort == .ultra ? "max" : effort.rawValue))
                XCTAssertEqual(body.objectValue?["input"]?.arrayValue?.first?.objectValue?["content"]?
                    .arrayValue?.first?.objectValue?["detail"], .string("original"))
            }
        }
    }
}
