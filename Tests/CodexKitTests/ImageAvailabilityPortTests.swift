@testable import CodexKit
import XCTest

final class ImageAvailabilityPortTests: XCTestCase {
    override func setUp() async throws { await TestURLProtocol.reset() }
    override func tearDown() async throws { await TestURLProtocol.reset() }

    func testDefaultAndAccessErrorsRetainOriginalReferences() async throws {
        struct DefaultStore: AgentImageAvailabilityChecking {}
        struct DeniedStore: AgentImageAvailabilityChecking {
            func isResolvable(fileID: String) async throws -> Bool { throw CocoaError(.fileReadNoPermission) }
        }
        let items = [message([image("file-a")])]
        for checker: (any AgentImageAvailabilityChecking)? in [nil, DefaultStore(), DeniedStore()] {
            let output = try await CodexResponsesImageAvailability.prepare(items, checker: checker)
            XCTAssertEqual(output, items)
        }
    }

    func testOnlyConfirmedMissingMessageAndToolImagesAreReplaced() async throws {
        let store = CountingStore(missing: ["missing"])
        let text: JSONValue = .object(["type": .string("input_text"), "text": .string("Keep"),
            "annotations": .array([.string("retain annotation")])])
        let imageValues = [text, image("missing"), image("available")]
        let items: [JSONValue] = [message(imageValues),
            .object(["type": .string("function_call_output"), "call_id": .string("call"), "output": .array(imageValues)]),
            .object(["type": .string("custom_tool_call_output"), "call_id": .string("custom"), "output": .array(imageValues)]),
            .object(["type": .string("function_call_output"), "output": .string("file missing is arbitrary text")]),
            .object(["type": .string("arbitrary"), "content": .array([image("missing")])]),
            .object(["type": .string("image_generation_call"), "result": .string("missing")])]
        var expected = items
        for index in 0..<3 {
            var object = try XCTUnwrap(expected[index].objectValue)
            object[index == 0 ? "content" : "output"] = .array([text, placeholder, image("available")])
            if index == 0 {
                object["internal_chat_message_metadata_passthrough"] = attribution(kinds: ["unknown", "images.unavailable", "unknown"],
                    sources: ["unknown", "harness", "unknown"])
            }
            expected[index] = .object(object)
        }
        let output = try await CodexResponsesImageAvailability.prepare(items, checker: store)
        XCTAssertEqual(output, expected)
        let calls = await store.calls
        XCTAssertEqual(calls, ["missing": 1, "available": 1])
        XCTAssertEqual(items.first, message(imageValues))
    }

    func testDistinctChecksAreConcurrentAndBoundedToEight() async throws {
        let store = CountingStore(missing: [])
        let images = (0..<24).flatMap { [image("file-\($0)"), image("file-\($0)")] }
        let items = [message(images)]
        let output = try await CodexResponsesImageAvailability.prepare(items, checker: store)
        XCTAssertEqual(output, items)
        let calls = await store.calls
        let maximum = await store.maximumActive
        XCTAssertEqual(calls.count, 24)
        XCTAssertTrue(calls.values.allSatisfy { $0 == 1 })
        XCTAssertGreaterThan(maximum, 1)
        XCTAssertLessThanOrEqual(maximum, 8)
    }

    func testInlineAndURLImagesNeverTriggerFileAvailabilityChecks() async throws {
        let store = CountingStore(missing: [])
        let items = [message([.object(["type": .string("input_image"), "image_url": .string("https://example.com/image.png")]),
            .object(["type": .string("input_image"), "image_url": .string("data:image/png;base64,eA==")])])]
        let output = try await CodexResponsesImageAvailability.prepare(items, checker: store)
        XCTAssertEqual(output, items)
        let calls = await store.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testActualFileDisappearanceAndRecoveryAreRecheckedWithoutRewritingDiskHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("image.png")
        let bytes = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII="))
        let original = message([image("owned-file")])
        for adapter in [TestStorageBackend.file, .sqlite, .realm] {
            let url = root.appendingPathComponent(adapter.rawValue)
            let store = try adapter.open(at: url)
            try await store.saveState(.init(threads: [.init(id: "t")], contextStateByThread: ["t": .init(
                threadID: "t", effectiveMessages: [], providerContext: CodexResponsesProviderState(items: [original]).agentProviderContext,
                generation: 1)]))
            let reopened = try adapter.open(at: url)
            let loaded = try await reopened.loadState()
            var context = try XCTUnwrap(loaded.contextStateByThread["t"]?.providerContext)
            var configuration = CodexResponsesBackendConfiguration()
            configuration.imageAvailabilityChecker = FileStore(files: ["owned-file": file])
            let backend = CodexResponsesBackend(configuration: configuration, urlSession: makeTestURLSession())
            // Every prepared request checks again: present, removed, restored.
            for available in [true, false, true] {
                if available { try bytes.write(to: file) } else { try FileManager.default.removeItem(at: file) }
                var expected = message([available ? image("owned-file") : placeholder])
                if !available, var object = expected.objectValue {
                    object["internal_chat_message_metadata_passthrough"] = attribution(kinds: ["images.unavailable"], sources: ["harness"])
                    expected = .object(object)
                }
                let expectedBodyItem = expected
                await TestURLProtocol.enqueue(.init(body: completed, inspect: { wire in
                    let body = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(try requestBodyData(for: wire)))
                    XCTAssertEqual(body.objectValue?["input"]?.arrayValue?.first, expectedBodyItem)
                }))
                let stream = try await begin(backend, context: context)
                for try await event in stream.events {
                    if case let .providerContextUpdated(_, updated) = event { context = updated }
                }
                XCTAssertEqual(CodexResponsesProviderState(context: context)?.items.first, original)
            }
            let saved = try await reopened.loadState()
            XCTAssertEqual(CodexResponsesProviderState(context: saved.contextStateByThread["t"]?.providerContext)?.items, [original])
        }
    }

    func testCompactionAvailabilityWaitDoesNotBlockForegroundTurn() async throws {
        let gate = GatedStore()
        var configuration = CodexResponsesBackendConfiguration()
        configuration.imageAvailabilityChecker = gate
        let backend = CodexResponsesBackend(configuration: configuration, urlSession: makeTestURLSession())
        let context = CodexResponsesProviderState(items: [message([image("missing")])]).agentProviderContext
        let compaction = Task {
            try await backend.compactContext(thread: .init(id: "compact"), effectiveHistory: [], providerContext: context,
                instructions: "", tools: [], session: demoSession())
        }
        await gate.waitUntilEntered()
        await TestURLProtocol.enqueue(.init(body: completed))
        let foreground = try await begin(backend, context: nil)
        for try await _ in foreground.events {}
        await TestURLProtocol.enqueue(.init(body: streamedCompactionReply(), inspect: { wire in
            let body = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(try requestBodyData(for: wire)))
            XCTAssertEqual(body.objectValue?["input"]?.arrayValue?.first?.objectValue?["content"]?.arrayValue,
                [.object(["type": .string("input_text"), "text": .string("[image unavailable]")])])
        }))
        await gate.release()
        let result = try await compaction.value
        XCTAssertEqual(result.effectiveMessages.first?.text, "[image unavailable]")
        XCTAssertEqual(CodexResponsesProviderState(context: context)?.items.first, message([image("missing")]))
    }

    func testCancellationIsNotConvertedIntoSuccessfulPreparation() async throws {
        let gate = GatedStore()
        let items = [message([image("file")])]
        let task = Task { try await CodexResponsesImageAvailability.prepare(items, checker: gate) }
        await gate.waitUntilEntered()
        task.cancel()
        await gate.release()
        do { _ = try await task.value; XCTFail("Cancellation must propagate") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testReplacementKeepsOtherPositionalAttributionAndMessageMetadata() async throws {
        var original = try XCTUnwrap(message([image("available"), image("missing")]).objectValue)
        var metadata = try XCTUnwrap(attribution(kinds: ["images.user", "images.user"], sources: ["user", "user"]).objectValue)
        metadata["custom_field"] = .string("keep")
        original["internal_chat_message_metadata_passthrough"] = .object(metadata)
        let output = try await CodexResponsesImageAvailability.prepare([.object(original)], checker: CountingStore(missing: ["missing"]))
        let result = try XCTUnwrap(output.first?.objectValue?["internal_chat_message_metadata_passthrough"]?.objectValue)
        XCTAssertEqual(result["custom_field"], .string("keep"))
        XCTAssertEqual(result["content_item_kinds"], .array([.string("images.user"), .string("images.unavailable")]))
        XCTAssertEqual(result["content_item_metadata"], attribution(kinds: [], sources: ["user", "harness"]).objectValue?["content_item_metadata"])
        XCTAssertEqual(original["internal_chat_message_metadata_passthrough"], .object(metadata))
    }

    func testAvailableFileIDsSurviveCompactionDiskReopenAndCheckpointTrimming() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let text: JSONValue = .object(["type": .string("input_text"), "text": .string("Keep")])
        let original = message([text, image("available")])
        let context = CodexResponsesProviderState(items: [original]).agentProviderContext
        await TestURLProtocol.enqueue(.init(body: streamedCompactionReply()))
        let backend = CodexResponsesBackend(urlSession: makeTestURLSession())
        let compacted = try await backend.compactContext(thread: .init(id: "t"), effectiveHistory: [], providerContext: context,
            instructions: "", tools: [], session: demoSession())
        XCTAssertEqual(CodexResponsesProviderState(context: compacted.providerContext)?.items.first, original)
        for adapter in [TestStorageBackend.file, .sqlite, .realm] {
            let url = root.appendingPathComponent(adapter.rawValue)
            let store = try adapter.open(at: url)
            try await store.saveState(.init(threads: [.init(id: "t")], contextStateByThread: ["t": .init(threadID: "t",
                effectiveMessages: compacted.effectiveMessages, providerContext: compacted.providerContext, generation: 1)]))
            let reopened = try adapter.open(at: url)
            let activation = try await reopened.loadThreadActivationState(id: "t", policy: .init(maximumMessageCount: 1))
            XCTAssertEqual(activation.effectiveMessages.map(\.text), ["Keep"])
            XCTAssertEqual(CodexResponsesProviderState(context: activation.contextState?.providerContext)?.items.first, original)
        }
        // Also exercise a real prefix trim, which must preserve the later file ID.
        let older = AgentMessage(threadID: "t", role: .user, text: "Old")
        let recent = try XCTUnwrap(compacted.effectiveMessages.first)
        let checkpoint: JSONValue = .object(["type": .string("compaction"), "encrypted_content": .string("opaque")])
        let expanded = CodexResponsesProviderState(items: [WorkingHistoryItem.visibleMessage(older).jsonValue, original, checkpoint]).agentProviderContext
        let rebased = CodexResponsesCheckpointContext.rebase(context: expanded, original: [older, recent], retained: [recent])
        XCTAssertEqual(CodexResponsesProviderState(context: rebased)?.items, [original, checkpoint])
    }

    private func image(_ id: String) -> JSONValue { .object(["type": .string("input_image"), "file_id": .string(id)]) }
    private func message(_ content: [JSONValue]) -> JSONValue {
        .object(["type": .string("message"), "role": .string("user"), "content": .array(content),
            "id": .string("original-message")])
    }
    private var placeholder: JSONValue { .object(["type": .string("input_text"), "text": .string("[image unavailable]")]) }
    private func attribution(kinds: [String], sources: [String]) -> JSONValue {
        .object(["content_item_kinds": .array(kinds.map(JSONValue.string)), "content_item_metadata": .array(sources.map {
            .object(["provenance": .object($0 == "harness" ? ["type": .string($0), "hook": .bool(false)] : ["type": .string($0)])])
        })])
    }
    private var completed: Data { Data("data: {\"type\":\"response.completed\",\"response\":{\"id\":\"done\"}}\n\n".utf8) }
    private func begin(_ backend: CodexResponsesBackend, context: AgentProviderContext?) async throws -> AgentTurnStream {
        try await backend.beginTurn(thread: .init(id: "t"), history: [], providerContext: context, message: Request(text: "Next"),
            instructions: "", responseFormat: nil, streamedStructuredOutput: nil, tools: [], session: demoSession())
    }
}

private actor CountingStore: AgentImageAvailabilityChecking {
    let missing: Set<String>
    var calls: [String: Int] = [:]
    var active = 0
    var maximumActive = 0
    init(missing: Set<String>) { self.missing = missing }
    func isResolvable(fileID: String) async throws -> Bool {
        calls[fileID, default: 0] += 1
        active += 1
        maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        try await Task.sleep(nanoseconds: 20_000_000)
        return !missing.contains(fileID)
    }
}

private struct FileStore: AgentImageAvailabilityChecking {
    let files: [String: URL]
    func isResolvable(fileID: String) async throws -> Bool {
        guard let url = files[fileID] else { return true }
        do { _ = try FileManager.default.attributesOfItem(atPath: url.path); return true }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return false }
    }
}

private actor GatedStore: AgentImageAvailabilityChecking {
    var entered = false
    var entry: CheckedContinuation<Void, Never>?
    var gate: CheckedContinuation<Bool, Never>?
    func isResolvable(fileID: String) async throws -> Bool {
        entered = true
        entry?.resume(); entry = nil
        return await withCheckedContinuation { gate = $0 }
    }
    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { entry = $0 } }
    }
    func release() { gate?.resume(returning: false); gate = nil }
}
