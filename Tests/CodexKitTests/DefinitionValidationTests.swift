@testable import CodexKit
import XCTest

final class DefinitionValidationTests: XCTestCase {
    override func setUp() async throws { await TestURLProtocol.reset() }
    override func tearDown() async throws { await TestURLProtocol.reset() }

    func testMalformedPolicyFieldsFailInsteadOfRemovingRestrictions() async throws {
        let policies: [[String: Any]] = [
            ["allowedToolNames": ["safe"], "maxToolCalls": "0"],
            ["allowedToolNames": "safe"], ["requiredToolNames": "safe"], ["toolSequence": 1],
            ["maxToolCalls": -1], ["maxToolCalls": 0.5],
            ["allowedToolNames": ["bad tool name"]], ["requiredToolNames": ["bad name"]],
            ["toolSequence": ["bad name"]], ["allowdToolNames": []],
        ]
        for policy in policies {
            let data = try JSONSerialization.data(withJSONObject: ["id": "restricted", "name": "Restricted",
                "instructions": "Use approved tools only.", "executionPolicy": policy])
            await TestURLProtocol.enqueue(.init(body: data))
            do {
                _ = try await loader().loadSkill(from: remote)
                XCTFail("Expected invalid policy to be rejected: \(policy)")
            } catch { XCTAssertEqual((error as? AgentDefinitionSourceError)?.code, "invalid_skill_definition") }
        }
    }

    func testMalformedStructuredDefinitionsDoNotFallBackToPlainText() async throws {
        for text in [#"{"instructions":"Go","executionPolicy":false}"#,
                     #"{"instructions":"Go","executionPolicy":[]}"#,
                     #"{"instructions":123}"#, #"{"instructions":"Go", broken}"#] {
            await TestURLProtocol.enqueue(.init(body: Data(text.utf8)))
            do {
                _ = try await loader().loadSkill(from: remote, id: "override", name: "Override")
                XCTFail("Malformed JSON definitions must fail even when the caller supplies identity")
            } catch { XCTAssertEqual((error as? AgentDefinitionSourceError)?.code, "invalid_skill_definition") }
        }
    }

    func testOptionalPoliciesAndPlainTextStillLoad() async throws {
        for suffix in ["", #", "executionPolicy":null"#, #", "executionPolicy":{}"#] {
            await TestURLProtocol.enqueue(.init(body: Data((#"{"instructions":"Go""# + suffix + "}").utf8)))
            let skill = try await loader().loadSkill(from: remote, id: "override", name: "Override")
            XCTAssertEqual(skill.id, "override")
            XCTAssertEqual(skill.instructions, "Go")
        }
        await TestURLProtocol.enqueue(.init(body: Data("  Follow these instructions.  ".utf8)))
        let plain = try await loader().loadSkill(from: remote, id: "plain")
        XCTAssertEqual(plain.instructions, "Follow these instructions.")
        XCTAssertNil(plain.executionPolicy)
    }

    func testUTF8BOMCannotBypassPolicyValidation() async throws {
        await TestURLProtocol.enqueue(.init(body: Data(("\u{FEFF}" + #" {"instructions":"Go","executionPolicy":{"maxToolCalls":"0"}}"#).utf8)))
        do {
            _ = try await loader().loadSkill(from: remote, id: "restricted")
            XCTFail("A byte-order mark must not turn an invalid policy into plain text")
        } catch { XCTAssertEqual((error as? AgentDefinitionSourceError)?.code, "invalid_skill_definition") }
        await TestURLProtocol.enqueue(.init(body: Data(("\u{FEFF}" + #" {"instructions":"Go","executionPolicy":{"maxToolCalls":0}}"#).utf8)))
        let skill = try await loader().loadSkill(from: remote, id: "restricted")
        XCTAssertEqual(skill.executionPolicy?.maxToolCalls, 0)
    }

    func testSizeLimitAlsoAppliesToPersonaAndSkillEntryPoints() async throws {
        await TestURLProtocol.enqueue(.init(body: Data("123456789".utf8)))
        do {
            _ = try await loader(limit: 8).loadPersonaStack(from: remote)
            XCTFail("Persona loading must enforce the limit")
        } catch { XCTAssertEqual((error as? AgentDefinitionSourceError)?.code, "definition_too_large") }
        await TestURLProtocol.enqueue(.init(body: Data("123456789".utf8)))
        do {
            _ = try await loader(limit: 8).loadSkill(from: remote, id: "skill")
            XCTFail("Skill loading must enforce the limit")
        } catch { XCTAssertEqual((error as? AgentDefinitionSourceError)?.code, "definition_too_large") }
    }

    func testValidPolicyPreservesEveryFieldIncludingEmptyAllowlist() async throws {
        await TestURLProtocol.enqueue(.init(body: Data(#"{"id":"restricted","instructions":"Go","executionPolicy":{"allowedToolNames":[],"requiredToolNames":["safe"],"toolSequence":["safe"],"maxToolCalls":0}}"#.utf8)))
        let skill = try await loader().loadSkill(from: remote)
        XCTAssertEqual(skill.executionPolicy, .init(allowedToolNames: [], requiredToolNames: ["safe"], toolSequence: ["safe"], maxToolCalls: 0))
    }

    func testEmptyAllowlistBlocksExecutionInTheRuntime() async throws {
        let runtime = try AgentRuntime(configuration: .init(sessionProvider: DesignReadOnlyProvider(),
            backend: InMemoryAgentBackend(), approvalPresenter: AutoApprovalPresenter(), stateStore: InMemoryRuntimeStateStore(),
            tools: [.init(definition: .init(name: "demo_lookup_profile", description: "Lookup", inputSchema: .object([:])),
                executor: .init { invocation, _ in
                    XCTFail("An empty allowlist must prevent execution")
                    return .success(invocation: invocation, text: "Unexpected")
                })],
            skills: [.init(id: "restricted", name: "Restricted", instructions: "No tools", executionPolicy: .init(allowedToolNames: []))]))
        let thread = try await runtime.createThread(skillIDs: ["restricted"])
        var sawBlockedCall = false
        for try await event in try await runtime.stream(Request(text: "please use the tool"), in: thread.id) {
            if case let .toolCallFinished(result) = event {
                sawBlockedCall = true
                XCTAssertFalse(result.success)
            }
        }
        XCTAssertTrue(sawBlockedCall)
    }

    func testFilesEnforceUTF8ByteLimitAndAcceptExactBoundary() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let value = "🙂é"
        let data = Data(value.utf8)
        try data.write(to: url)
        let exact = try await loader(limit: data.count).loadText(from: .file(url))
        XCTAssertEqual(exact, value)
        do {
            _ = try await loader(limit: data.count - 1).loadText(from: .file(url))
            XCTFail("Expected byte limit")
        } catch { XCTAssertEqual((error as? AgentDefinitionSourceError)?.code, "definition_too_large") }
    }

    func testLargeSparseFileIsRejected() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data()))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 128 * 1_024 * 1_024)
        try handle.close()
        do { _ = try await loader(limit: 32).loadText(from: .file(url)); XCTFail("Expected byte limit") }
        catch { XCTAssertEqual((error as? AgentDefinitionSourceError)?.code, "definition_too_large") }
    }

    func testRemoteLimitHandlesKnownUnknownAndUnderstatedLengths() async throws {
        for headers in [[:], ["Content-Length": "100"], ["Content-Length": "1"]] {
            await TestURLProtocol.enqueue(.init(headers: headers, body: Data("123456789".utf8)))
            do { _ = try await loader(limit: 8).loadText(from: remote); XCTFail("Expected byte limit") }
            catch { XCTAssertEqual((error as? AgentDefinitionSourceError)?.code, "definition_too_large") }
        }
        await TestURLProtocol.enqueue(.init(body: Data("🙂🙂".utf8)))
        let exact = try await loader(limit: 8).loadText(from: remote)
        XCTAssertEqual(exact, "🙂🙂")
    }

    func testLoaderPreservesHTTPAndUTF8Errors() async throws {
        await TestURLProtocol.enqueue(.init(statusCode: 404, body: Data("Missing".utf8)))
        do { _ = try await loader().loadText(from: remote); XCTFail("Expected HTTP error") }
        catch { XCTAssertEqual(error as? AgentDefinitionSourceError, .unsupportedRemoteResponse(404)) }
        await TestURLProtocol.enqueue(.init(body: Data([0xFF])))
        do { _ = try await loader().loadText(from: remote); XCTFail("Expected UTF8 error") }
        catch { XCTAssertEqual(error as? AgentDefinitionSourceError, .unreadableContent()) }
    }

    func testInvalidLimitsAndCancelledCallsDoNotStartRequests() async throws {
        for limit in [0, -1] {
            do { _ = try await loader(limit: limit).loadText(from: remote); XCTFail("Expected invalid limit") }
            catch { XCTAssertEqual((error as? AgentDefinitionSourceError)?.code, "invalid_definition_limit") }
        }
        let loader = loader()
        let source = remote
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await loader.loadText(from: source)
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {}
    }

    private var remote: AgentDefinitionSource { .remote(URL(string: "https://example.com/definition")!) }
    private func loader(limit: Int = 1_024 * 1_024) -> AgentDefinitionSourceLoader {
        .init(urlSession: makeTestURLSession(), maximumDefinitionBytes: limit)
    }
}
