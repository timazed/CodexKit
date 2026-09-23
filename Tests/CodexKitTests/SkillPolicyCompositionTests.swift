@testable import CodexKit
import XCTest

final class SkillPolicyCompositionTests: XCTestCase {
    func testSkillsComposeRestrictivelyAndPreviewIncludesRuntimeCeiling() async throws {
        let runtime = try makePolicyRuntime(policy: .init(allowedToolNames: ["a", "b", "c"], requiredToolNames: ["a"],
            toolSequence: ["a"], maxToolCalls: 8, maxToolRounds: 3, maxToolCallsByName: ["a": 2, "b": 4], maximumParallelToolCalls: 7),
            maximumParallel: 3)
        try await runtime.registerSkill(.init(id: "extra", name: "Extra", instructions: "", executionPolicy:
            .init(allowedToolNames: ["a", "b"], requiredToolNames: ["b"], toolSequence: ["a", "b"], maxToolCalls: 6,
                maxToolRounds: 2, maxToolCallsByName: ["a": 1, "c": 0], maximumParallelToolCalls: 4)))
        let thread = try await runtime.createThread(skillIDs: ["policy"])
        let preview = try await runtime.resolvedInstructionsPreviewDetails(for: thread.id, request: .init(text: "Go", skillSelection: .append(["extra"])))
        let policy = try XCTUnwrap(preview.effectiveToolPolicy)
        XCTAssertEqual(policy.allowedToolNames, ["a", "b"])
        XCTAssertEqual(policy.requiredToolNames, ["a", "b"])
        XCTAssertEqual(policy.toolSequence, ["a", "b"])
        XCTAssertEqual(policy.maxToolCalls, 6)
        XCTAssertEqual(policy.maxToolRounds, 2)
        XCTAssertEqual(policy.maxToolCallsByName, ["a": 1, "b": 4, "c": 0])
        XCTAssertEqual(policy.maximumParallelToolCalls, 3)
        let reversed = try await runtime.resolvedInstructionsPreviewDetails(for: thread.id,
            request: .init(text: "Go", skillSelection: .replace(["extra", "policy"])))
        XCTAssertEqual(reversed.effectiveToolPolicy, policy)
    }

    func testConflictingSequencesFailBeforeExecution() async throws {
        let runtime = try makePolicyRuntime(policy: .init(toolSequence: ["a", "b"]))
        try await runtime.registerSkill(.init(id: "other", name: "Other", instructions: "",
            executionPolicy: .init(toolSequence: ["a", "c"])))
        let thread = try await runtime.createThread(skillIDs: ["policy"])
        do {
            _ = try await runtime.resolvedInstructionsPreviewDetails(for: thread.id,
                request: .init(text: "Go", skillSelection: .append(["other"])))
            XCTFail("Conflicting prefixes must fail")
        } catch { XCTAssertEqual((error as? AgentRuntimeError)?.code, "conflicting_skill_tool_sequences") }
    }

    func testNewDynamicPolicyFieldsAndStrictValidation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("skill.json")
        let loader = AgentDefinitionSourceLoader()
        let valid = #"{"id":"test","instructions":"Go","executionPolicy":{"maxToolRounds":2,"maxToolCallsByName":{"a":3},"maximumParallelToolCalls":2,"webSearch":{"mode":"indexed","allowedDomains":["Example.com"]}}}"#
        try Data(valid.utf8).write(to: url)
        let skill = try await loader.loadSkill(from: .file(url))
        XCTAssertEqual(skill.executionPolicy?.maxToolRounds, 2)
        XCTAssertEqual(skill.executionPolicy?.maxToolCallsByName, ["a": 3])
        XCTAssertEqual(skill.executionPolicy?.maximumParallelToolCalls, 2)
        XCTAssertEqual(skill.executionPolicy?.webSearch?.mode, .indexed)
        for policy in [
            #"{"maxToolRounds":-1}"#, #"{"maxToolRounds":1.5}"#, #"{"maxToolRounds":"2"}"#,
            #"{"maxToolCallsByName":{"a":-1}}"#, #"{"maxToolCallsByName":{"bad name":1}}"#,
            #"{"maximumParallelToolCalls":0}"#, #"{"maximumParallelToolCalls":-1}"#,
            #"{"webSearch":{"mode":"future"}}"#, #"{"webSearch":{"mode":"live","allowedDomain":[]}}"#,
            #"{"webSearch":{"mode":"live","allowedDomains":["https://example.com"]}}"#,
        ] {
            try Data("{\"id\":\"test\",\"instructions\":\"Go\",\"executionPolicy\":\(policy)}".utf8).write(to: url)
            do { _ = try await loader.loadSkill(from: .file(url)); XCTFail("Accepted \(policy)") }
            catch { XCTAssertEqual((error as? AgentDefinitionSourceError)?.code, "invalid_skill_definition") }
        }
    }

    func testOldResultEnvelopesDecodeWithoutStructuredFailure() throws {
        let value = try JSONDecoder().decode(ToolResultEnvelope.self,
            from: Data(#"{"invocationID":"a","toolName":"a","success":false,"content":[],"errorMessage":"failed"}"#.utf8))
        XCTAssertNil(value.failure)
        XCTAssertEqual(value.errorMessage, "failed")
    }
}
