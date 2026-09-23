import CodexKit
import CodexKitRealm
import CodexKitSQLite
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest

/// Explicitly opt in; ordinary CI never reads a real account or uses its quota.
final class LiveProviderTests: XCTestCase {
    func testLiveStreamingOutputFormats() async throws {
        let session = try currentSession()
        let backend = CodexResponsesBackend(configuration: .init(enableWebSearch: false, enableImageGeneration: false,
            requestRetryPolicy: .disabled, maximumModelPasses: 1, maximumResponseBytes: 1_024 * 1_024))
        let runtime = try AgentRuntime(configuration: .init(sessionProvider: LiveSessionProvider(session: session),
            backend: backend, approvalPresenter: AutoApprovalPresenter(), stateStore: InMemoryRuntimeStateStore(),
            turnLimits: .init(maximumToolCalls: 0, maximumDuration: 60)))
        let recordSchema = JSONSchema.object(properties: ["index": .integer, "text": .string()], required: ["index", "text"])
        let jsonThread = try await runtime.createThread()
        let json = try await runtime.send(Request(text: "Return index 1 and text ok. Do not use tools."), in: jsonThread.id,
            output: AgentJSONResponseFormat<LiveStreamingRecord>(name: "record", schema: recordSchema))
        XCTAssertEqual(json.index, 1)

        let recordsThread = try await runtime.createThread()
        let recordsFormat = AgentRecordResponseFormat(name: "records", record: LiveStreamingRecord.self,
            schema: recordSchema, minimumRecords: 3, maximumRecords: 3)
        var previews = 0, committed = false
        for try await event in try await runtime.stream(Request(text: "Return three records with index 1, 2, 3 and text of one short sentence each. Do not use tools."),
            in: recordsThread.id, output: recordsFormat) {
            if case .format(_, .recordCompleted) = event { previews += 1 }
            if case let .outputCommitted(_, result) = event { XCTAssertEqual(result.records.map(\.index), [1, 2, 3]); committed = true }
        }
        XCTAssertEqual(previews, 3); XCTAssertTrue(committed)

        let xmlThread = try await runtime.createThread()
        let format = AgentXMLResponseFormat(name: "notes", schema: .element("response", children: .sequence([
            .element("note", text: .string, attributes: ["priority": .required(.string(enum: ["low", "high"]))], occurs: .range(min: 3, max: 3))
        ])))
        var elements = 0
        for try await event in try await runtime.stream(Request(text: "Return three concise notes about testing software. Set priority to low or high. Do not use tools."),
            in: xmlThread.id, output: format) {
            if case .format(_, .elementCompleted) = event { elements += 1 }
            if case let .outputCommitted(_, document) = event { XCTAssertEqual(document.root.children.count, 3) }
        }
        XCTAssertEqual(elements, 3)
    }

    func testLivePlainAndStructuredCompletion() async throws {
        let session = try currentSession()
        let backend = CodexResponsesBackend(configuration: .init(enableWebSearch: false, enableImageGeneration: false,
            requestRetryPolicy: .disabled, maximumModelPasses: 1, maximumResponseBytes: 1_024 * 1_024))
        let runtime = try AgentRuntime(configuration: .init(sessionProvider: LiveSessionProvider(session: session),
            backend: backend, approvalPresenter: AutoApprovalPresenter(), stateStore: InMemoryRuntimeStateStore(),
            turnLimits: .init(maximumToolCalls: 0, maximumDuration: 60)))
        let thread = try await runtime.createThread()
        let plain = try await runtime.send(Request(text: "Reply with exactly OK. Do not use tools."), in: thread.id)
        XCTAssertFalse(plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let structured = try await runtime.send(Request(text: "Return an object with value set to ok. Do not use tools."),
            in: thread.id, response: LiveResult.self)
        XCTAssertEqual(structured.value.lowercased(), "ok")
    }

    func testLiveImageCompactionAndDatabaseReopenPreserveContext() async throws {
        let session = try currentSession()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try redImage()
        for adapter in [TestStorageBackend.sqlite, .realm] {
            let url = directory.appendingPathComponent(adapter.rawValue)
            let open: () throws -> any RuntimeStateStoring = {
                adapter == .sqlite ? try SQLiteRuntimeStateStore(url: url) : try RealmRuntimeStateStore(url: url)
            }
            let backend = CodexResponsesBackend(configuration: .init(streamIdleTimeout: 45,
                enableWebSearch: false, enableImageGeneration: false, stateManagement: .clientManaged,
                requestRetryPolicy: .disabled, maximumModelPasses: 1, maximumResponseBytes: 8 * 1_024 * 1_024))
            let makeRuntime: () throws -> AgentRuntime = {
                try .init(configuration: .init(sessionProvider: LiveSessionProvider(session: session), backend: backend,
                    approvalPresenter: AutoApprovalPresenter(), stateStore: open(),
                    turnLimits: .init(maximumToolCalls: 0, maximumDuration: 60),
                    contextCompaction: .init(isEnabled: true, mode: .manual, strategy: .remoteOnly)))
            }
            let runtime = try makeRuntime()
            let thread = try await runtime.createThread()
            let marker = UUID().uuidString
            let initial = try await runtime.send(Request(text: "Remember this exact marker: \(marker). Inspect the image. Return the marker and its dominant color in lowercase. Do not use tools.", images: [image]),
                in: thread.id, response: LiveImageResult.self)
            XCTAssertEqual(initial.marker, marker)
            XCTAssertEqual(initial.color.lowercased(), "red")
            let compacted = try await runtime.compactThreadContext(id: thread.id)
            XCTAssertEqual(compacted.generation, 1)
            await runtime.deactivateThread(id: thread.id)
            let reopened = try makeRuntime()
            _ = try await reopened.restore()
            _ = try await reopened.resumeThread(id: thread.id)
            let recalled = try await reopened.send(Request(text: "Return the exact marker and image color established earlier. If unavailable, return missing. Do not use tools."),
                in: thread.id, response: LiveImageResult.self)
            XCTAssertEqual(recalled.marker, marker, "Context failed after \(adapter) reopen")
            XCTAssertEqual(recalled.color.lowercased(), "red")
        }
    }

    private func currentSession() throws -> ChatGPTSession {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CODEXKIT_RUN_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Set CODEXKIT_RUN_LIVE_TESTS=1 to exercise a saved CodexKit session.")
        }
        let entries: [(String, String)]
        if environment["CODEXKIT_LIVE_KEYCHAIN_SERVICE"] != nil || environment["CODEXKIT_LIVE_KEYCHAIN_ACCOUNT"] != nil {
            entries = [(environment["CODEXKIT_LIVE_KEYCHAIN_SERVICE"] ?? "CodexKit.ChatGPTSession",
                        environment["CODEXKIT_LIVE_KEYCHAIN_ACCOUNT"] ?? "default")]
        } else {
            entries = [("CodexKit.ChatGPTSession", "default"),
                       ("AssistantRuntimeDemoApp.ChatGPTSession", "AssistantRuntimeDemoApp")]
        }
        for (service, account) in entries {
            if let session = try KeychainSessionSecureStore(service: service, account: account).loadSession(),
               !session.requiresRefresh() { return session }
        }
        throw XCTSkip("No current SDK/demo session is saved on this Mac. Sign in through the Mac host app, then rerun live checks.")
    }

    private func redImage() throws -> AgentImageAttachment {
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return .init(mimeType: "image/png", data: data as Data)
    }
}

private struct LiveSessionProvider: AgentSessionProviding {
    let session: ChatGPTSession
    func currentSession() async -> ChatGPTSession? { session }
}

private struct LiveResult: AgentStructuredOutput {
    let value: String
    static let responseFormat = AgentStructuredOutputFormat(name: "result",
        schema: .object(properties: ["value": .string(enum: ["ok"])], required: ["value"], additionalProperties: false))
}

private struct LiveStreamingRecord: Codable, Sendable {
    let index: Int
    let text: String
}

private struct LiveImageResult: AgentStructuredOutput {
    let marker: String
    let color: String
    static let responseFormat = AgentStructuredOutputFormat(name: "image_memory",
        schema: .object(properties: ["marker": .string(), "color": .string()],
            required: ["marker", "color"], additionalProperties: false))
}
