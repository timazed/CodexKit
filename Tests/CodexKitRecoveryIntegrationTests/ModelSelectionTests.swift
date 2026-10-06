import CodexKit
import Foundation
import RecoveryIntegrationSupport
import XCTest

@MainActor
final class ModelSelectionTests: XCTestCase {
    var directory: URL!
    override func setUp() async throws { directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: directory) }

    func testBuiltInPolicySelectsSupportedPairFromAccountCatalog() async throws {
        let catalog: [String: Any] = ["models": [["slug": "gpt-6.1-sol", "visibility": "list",
            "display_name": "Available", "supported_reasoning_levels": [["effort": "medium"]],
            "default_reasoning_level": "medium", "input_modalities": ["text"], "context_window": 10000]]]
        FixtureTransport.configure(["catalog": [.catalog(try JSONSerialization.data(withJSONObject: catalog))], "news": [.complete("selected")]])
        let selector = PreferredAvailableCodexModelSelector(candidates: [
            .init(model: "missing", reasoningEffort: .high),
            .init(model: "gpt-6.1-sol", reasoningEffort: .high),
            .init(model: "gpt-6.1-sol", reasoningEffort: .medium)
        ], refreshPolicy: .refresh)
        let runtime = try fixtureRuntime(selector: selector)
        let thread = try await runtime.createThread()
        let store = AgentStructuredRecoveryStore(directory: directory)
        var request = Request(text: "news", executionMode: .ephemeral)
        request.selectionPurpose = "host-only-purpose"
        request.modelRequirements = .init(minimumContextWindowTokenCount: 5000)
        let handle = try await runtime.prepareStructuredRecovery(request, in: thread.id, response: FixtureOutput.self, store: store)
        XCTAssertEqual(FixtureTransport.generationCount, 0)
        _ = try await runtime.sendRecovering(handle, response: FixtureOutput.self, store: store) { _ in true }
        XCTAssertEqual(FixtureTransport.captures.filter { $0.method == "GET" }.count, 1)
        let generation = try XCTUnwrap(FixtureTransport.captures.first { $0.method == "POST" })
        XCTAssertEqual(generation.model, "gpt-6.1-sol")
        XCTAssertEqual(generation.effort, "medium")
        XCTAssertFalse(String(decoding: generation.body, as: UTF8.self).contains("host-only-purpose"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: generation.body) as? [String: Any])
        XCTAssertEqual((json["tools"] as? [Any])?.count, 0)
        XCTAssertEqual(json["tool_choice"] as? String, "none")
    }

    func testFixedOverrideBypassesSelectorAndOrdinarySendResolvesOnce() async throws {
        FixtureTransport.configure(["news": [.complete("fixed"), .complete("dynamic")]])
        let selector = PurposeSelector()
        let runtime = try fixtureRuntime(selector: selector)
        let thread = try await runtime.createThread()
        var request = Request(text: "news", executionMode: .ephemeral)
        request.selectionPurpose = "news"
        request.modelOverride = .init(model: "gpt-5.5", reasoningEffort: .medium)
        _ = try await runtime.send(request, in: thread.id, response: FixtureOutput.self)
        let before = await selector.purposes
        XCTAssertTrue(before.isEmpty)
        XCTAssertEqual(FixtureTransport.captures.first?.model, "gpt-5.5")
        request.modelOverride = nil
        _ = try await runtime.send(request, in: thread.id, response: FixtureOutput.self)
        let after = await selector.purposes
        XCTAssertEqual(after, ["news"])
        XCTAssertEqual(FixtureTransport.captures.last?.effort, "high")
        XCTAssertEqual(FixtureTransport.captures.filter { $0.method == "GET" }.count, 0)
    }

    func testManualReselectionCreatesNewFrozenConfiguration() async throws {
        FixtureTransport.configure(["news": [.disconnect, .complete("new-model")]])
        let selector = PurposeSelector()
        let runtime = try fixtureRuntime(selector: selector)
        let thread = try await runtime.createThread()
        let store = AgentStructuredRecoveryStore(directory: directory)
        let handle = try await runtime.prepareStructuredRecovery(Request(text: "news", executionMode: .ephemeral),
            in: thread.id, response: FixtureOutput.self, store: store, maximumAttempts: 1)
        do { _ = try await runtime.sendRecovering(handle, response: FixtureOutput.self, store: store) { _ in true }; XCTFail() }
        catch { XCTAssertEqual((error as? AgentRuntimeError)?.interruption?.outcome, .disconnected) }
        await selector.changeModel("gpt-5.5")
        let retry = try await runtime.retryStructuredRecovery(handle, retryActionID: UUID(), store: store,
            maximumAttempts: 2, selection: .reselect)
        _ = try await runtime.sendRecovering(retry, response: FixtureOutput.self, store: store) { _ in true }
        XCTAssertEqual(FixtureTransport.captures.map(\.model), ["gpt-5.6-sol", "gpt-5.5"])
        let purposes = await selector.purposes
        XCTAssertEqual(purposes.count, 2)
        let previous = try await runtime.structuredRecoveryStatus(handle, store: store)
        let current = try await runtime.structuredRecoveryStatus(retry, store: store)
        XCTAssertEqual(previous.attemptsUsed, 1)
        XCTAssertEqual(current.previousOperationID, handle.id)
        XCTAssertEqual(current.maximumAttempts, 2)
    }

    func testRecoveryTelemetryUsesExistingSinkWithoutPrivateContent() async throws {
        FixtureTransport.configure(["news": [.disconnect, .complete("private-output")]])
        let sink = CapturedLogs()
        let runtime = try fixtureRuntime(logging: .init(sink: sink))
        let thread = try await runtime.createThread()
        let store = AgentStructuredRecoveryStore(directory: directory)
        let handle = try await runtime.prepareStructuredRecovery(Request(text: "news", executionMode: .ephemeral),
            in: thread.id, response: FixtureOutput.self, store: store,
            retryPolicy: .init(backoff: .init(initialBackoff: 0, maxBackoff: 0)))
        _ = try await runtime.sendRecovering(handle, response: FixtureOutput.self, store: store) { _ in true }
        _ = try await runtime.structuredRecoveryReceipt(handle, store: store)
        _ = try await runtime.sendRecovering(handle, response: FixtureOutput.self, store: store) { _ in
            XCTFail("A saved receipt must not authorize another attempt")
            return false
        }
        try await runtime.acknowledgeStructuredRecovery(handle, store: store)
        let entries = sink.entries.filter { $0.category == .recovery }
        XCTAssertTrue(entries.contains { $0.metadata["event"] == "recovery.operation.prepared" })
        XCTAssertTrue(entries.contains { $0.metadata["event"] == "recovery.attempt.reserved" })
        XCTAssertTrue(entries.contains { $0.metadata["event"] == "recovery.attempt.transmission_authorized" })
        XCTAssertTrue(entries.contains { $0.metadata["event"] == "recovery.attempt.failed" })
        XCTAssertTrue(entries.contains { $0.metadata["event"] == "recovery.receipt.saved" })
        XCTAssertEqual(entries.filter { $0.metadata["event"] == "recovery.receipt.retrieved" }.count, 2)
        XCTAssertTrue(entries.contains { $0.metadata["event"] == "recovery.receipt.acknowledged" })
        XCTAssertTrue(entries.allSatisfy { $0.metadata["event_version"] == "1" })
        XCTAssertTrue(entries.allSatisfy { $0.metadata["operation_id"] == handle.id.uuidString })
        XCTAssertEqual(FixtureTransport.generationCount, 2)
        let text = entries.map { $0.message + String(describing: $0.metadata) }.joined()
        for secret in ["private-output", "fixture-token", "fixture-account", "fixture@example.test"] {
            XCTAssertFalse(text.contains(secret))
        }
    }
}

private final class CapturedLogs: AgentLogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AgentLogEntry] = []
    var entries: [AgentLogEntry] { lock.withLock { storage } }
    func log(_ entry: AgentLogEntry) { lock.withLock { storage.append(entry) } }
}
