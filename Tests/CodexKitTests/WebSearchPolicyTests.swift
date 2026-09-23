@testable import CodexKit
import XCTest

final class WebSearchPolicyTests: XCTestCase {
    override func setUp() async throws { await TestURLProtocol.reset() }
    override func tearDown() async throws { await TestURLProtocol.reset() }

    private func wireSearch(configuration: CodexResponsesBackendConfiguration,
        constraint: AgentWebSearchPolicy? = nil, compaction: Bool = false) throws -> JSONValue? {
        let request = try CodexResponsesRequestFactory(configuration: configuration, encoder: JSONEncoder())
            .buildURLRequest(threadConfiguration: configuration.defaultThreadConfiguration, instructions: "",
                responseContract: nil, threadID: "thread", items: [], tools: [], session: demoSession(),
                isCompaction: compaction, webSearch: constraint)
        let json = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(request.httpBody))
        return json.objectValue?["tools"]?.arrayValue?.first { $0.objectValue?["type"] == .string("web_search") }
    }

    func testBackendDefaultsAndExplicitDisableRemainUpperBounds() throws {
        XCTAssertNil(try wireSearch(configuration: .init()))
        XCTAssertNotNil(try wireSearch(configuration: .init(enableWebSearch: true)))
        XCTAssertNil(try wireSearch(configuration: .init(enableWebSearch: true), constraint: .init(mode: .disabled)))
        XCTAssertNil(try wireSearch(configuration: .init(enableWebSearch: false), constraint: .init(mode: .live)))
        XCTAssertNil(try wireSearch(configuration: .init(enableWebSearch: true), compaction: true))
        let cached = try wireSearch(configuration: .init(enableWebSearch: true, webSearchPolicy: .init(mode: .cached)),
            constraint: .init(mode: .live))
        XCTAssertEqual(cached?.objectValue?["external_web_access"], .bool(false))
    }

    func testCachedIndexedAndLiveUseVerifiedUpstreamFields() throws {
        for mode in [AgentWebSearchPolicy.Mode.cached, .indexed, .live] {
            let search = try XCTUnwrap(wireSearch(configuration: .init(enableWebSearch: true), constraint: .init(mode: mode)))
            XCTAssertEqual(search.objectValue?["external_web_access"], .bool(mode != .cached))
            XCTAssertEqual(search.objectValue?["indexed_web_access"], mode == .indexed ? .bool(true) : nil)
        }
    }

    func testDomainsAreNormalizedAndIntersectAsSubtrees() throws {
        let broad = AgentWebSearchPolicy(mode: .live, allowedDomains: [" Example.COM. ", "docs.example.com", "other.org"])
        let narrow = AgentWebSearchPolicy(mode: .indexed, allowedDomains: ["docs.example.com", "unrelated.org"])
        let effective = try broad.narrowed(by: narrow)
        XCTAssertEqual(effective.mode, .indexed)
        XCTAssertEqual(effective.allowedDomains, ["docs.example.com"])
        let search = try wireSearch(configuration: .init(enableWebSearch: true, webSearchPolicy: broad), constraint: narrow)
        XCTAssertEqual(search?.objectValue?["filters"]?.objectValue?["allowed_domains"], .array([.string("docs.example.com")]))
        XCTAssertEqual(try broad.narrowed(by: .init(mode: .cached)).mode, .cached)
        XCTAssertEqual(try broad.narrowed(by: .init(mode: .live, allowedDomains: ["notexample.com"])).mode, .disabled)
        XCTAssertEqual(try broad.narrowed(by: .init(mode: .live, allowedDomains: [])).mode, .disabled)
        XCTAssertEqual(try broad.narrowed(by: .init(mode: .disabled)).mode, .disabled)
        XCTAssertEqual(try narrow.narrowed(by: broad), effective)
    }

    func testInvalidDomainsAndUnsupportedRestrictionsFailExplicitly() throws {
        for domain in ["https://example.com", "example.com/path", "*.example.com", "example.com:443",
            "a@example.com", "127.0.0.1", "foo..com", "-foo.com", "foo-.com", "éxample.com", ""] {
            XCTAssertThrowsError(try AgentWebSearchPolicy(mode: .live, allowedDomains: [domain]).normalized())
        }
        let capabilities = AgentWebSearchCapabilities(defaultPolicy: .init(mode: .live), supportedModes: [.live])
        for restriction in [AgentWebSearchPolicy(mode: .cached), .init(mode: .live, allowedDomains: ["example.com"])] {
            XCTAssertThrowsError(try capabilities.resolve(restriction)) {
                XCTAssertEqual(($0 as? AgentRuntimeError)?.code, "unsupported_backend_capability")
            }
        }
        XCTAssertEqual(try capabilities.resolve(.init(mode: .disabled)).mode, .disabled)
    }

    func testSkillAndRequestRestrictionsPersistAcrossHostToolPasses() async throws {
        let backend = CodexResponsesBackend(configuration: .init(enableWebSearch: true,
            webSearchPolicy: .init(mode: .live, allowedDomains: ["example.com"])), urlSession: makeTestURLSession())
        let runtime = try makePolicyRuntime(policy: .init(webSearch: .init(mode: .indexed, allowedDomains: ["docs.example.com"])),
            tools: [policyTool("a")], backend: backend)
        try await runtime.registerSkill(.init(id: "cached", name: "Cached", instructions: "",
            executionPolicy: .init(webSearch: .init(mode: .cached))))
        let thread = try await runtime.createThread(skillIDs: ["policy", "cached"])
        let request = Request(text: "Go", webSearch: .init(mode: .live, allowedDomains: ["example.com", "another.org"]))
        let preview = try await runtime.resolvedInstructionsPreviewDetails(for: thread.id, request: request)
        XCTAssertEqual(preview.effectiveWebSearchPolicy, .init(mode: .cached, allowedDomains: ["docs.example.com"]))
        let check: @Sendable (URLRequest) throws -> Void = { request in
            let value = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(requestBodyData(for: request)))
            let search = value.objectValue?["tools"]?.arrayValue?.first { $0.objectValue?["type"] == .string("web_search") }
            XCTAssertEqual(search?.objectValue?["external_web_access"], .bool(false))
            XCTAssertEqual(search?.objectValue?["filters"]?.objectValue?["allowed_domains"], .array([.string("docs.example.com")]))
        }
        let first = "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"function_call\",\"name\":\"a\",\"call_id\":\"a\",\"arguments\":\"{}\"}}\n\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"first\"}}\n\n"
        await TestURLProtocol.enqueue(.init(body: Data(first.utf8), inspect: check))
        await enqueuePolicyAnswer(inspect: check)
        _ = try await runtime.send(request, in: thread.id)
    }

    func testUnadvertisedBackendCannotSilentlyIgnoreSearchRestriction() async throws {
        let runtime = try makePolicyRuntime(policy: .init(webSearch: .init(mode: .disabled)), backend: InMemoryAgentBackend())
        let thread = try await runtime.createThread(skillIDs: ["policy"])
        do {
            _ = try await runtime.send(Request(text: "Go"), in: thread.id)
            XCTFail("Expected unsupported capability")
        } catch { XCTAssertEqual((error as? AgentRuntimeError)?.code, "unsupported_backend_capability") }
    }
}
