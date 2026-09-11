@testable import CodexKit
import CodexKitRealm
import CodexKitSQLite
import XCTest

final class CompactionTransportTests: XCTestCase {
    override func setUp() async throws { await TestURLProtocol.reset() }
    override func tearDown() async throws { await TestURLProtocol.reset() }

    func testKnownUnknownAndUnderstatedLengthsRespectExactByteLimit() async throws {
        for headers in [[:], ["Content-Length": "10000"], ["Content-Length": "1"]] {
            await TestURLProtocol.enqueue(.init(headers: headers, body: compactReply))
            do { _ = try await compact(configuration: .init(maximumResponseBytes: compactReply.count - 1)); XCTFail("Expected byte limit") }
            catch { XCTAssertEqual((error as? AgentRuntimeError)?.executionLimit, .responseBytes) }
        }
        for limit in [compactReply.count, nil] {
            await TestURLProtocol.enqueue(.init(body: compactReply))
            let result = try await compact(configuration: .init(maximumResponseBytes: limit))
            XCTAssertEqual(result.providerContext?.payload.objectValue?["items"]?.arrayValue?.last?.objectValue?["encrypted_content"], .string("Summary"))
        }
    }

    func testErrorResponsesKeepHTTPDetailsAndBoundTheirBodies() async throws {
        let body = Data(#"{"error":{"code":"limited","type":"rate_limit"}}"#.utf8)
        await TestURLProtocol.enqueue(.init(statusCode: 429, headers: ["x-request-id": "request", "Retry-After": "3"], body: body))
        do { _ = try await compact(); XCTFail("Expected HTTP failure") }
        catch let error as AgentRuntimeError {
            XCTAssertEqual(error.code, "responses_compact_http_status_429")
            XCTAssertEqual(error.http?.statusCode, 429)
            XCTAssertEqual(error.http?.providerCode, "limited")
            XCTAssertEqual(error.http?.providerType, "rate_limit")
            XCTAssertEqual(error.http?.requestID, "request")
            XCTAssertEqual(error.http?.retryAfter, 3)
        }
        for limit in [16, nil] {
            await TestURLProtocol.enqueue(.init(statusCode: 401, headers: ["Content-Length": "100000000"],
                body: Data(repeating: 120, count: AgentStoreLimits.maximumResponseErrorBodyByteCount + 32)))
            do { _ = try await compact(configuration: .init(maximumResponseBytes: limit)); XCTFail("Expected unauthorized failure") }
            catch let error as AgentRuntimeError {
                XCTAssertEqual(error.code, "unauthorized")
                XCTAssertEqual(error.http?.statusCode, 401)
                XCTAssertLessThan(error.message.utf8.count, (limit ?? AgentStoreLimits.maximumResponseErrorBodyByteCount) + 200)
            }
        }
    }

    func testLargeResponsesPreserveBytesAndEnforceLimitsAcrossBufferBoundaries() async throws {
        for size in [65_535, 65_536, 65_537, 131_089] {
            let text = String(repeating: "x", count: size - compactReply.count) + "Summary"
            let body = Data(String(decoding: compactReply, as: UTF8.self)
                .replacingOccurrences(of: "Summary", with: text).utf8)
            XCTAssertEqual(body.count, size)
            await TestURLProtocol.enqueue(.init(headers: ["Content-Length": "1"], body: body))
            let result = try await compact(configuration: .init(maximumResponseBytes: size))
            XCTAssertEqual(result.providerContext?.payload.objectValue?["items"]?.arrayValue?.last?.objectValue?["encrypted_content"], .string(text))
            await TestURLProtocol.enqueue(.init(body: body))
            do {
                _ = try await compact(configuration: .init(maximumResponseBytes: size - 1))
                XCTFail("Expected exact response limit at \(size)")
            } catch { XCTAssertEqual((error as? AgentRuntimeError)?.executionLimit, .responseBytes) }
        }
    }

    func testDownloadFailureCannotCommitAPartiallyBufferedResponse() async throws {
        var body = Data("data: {\"type\":\"response.created\"}\n\n".utf8)
        body.append(Data(repeating: 32, count: 70_000))
        await TestURLProtocol.enqueue(.init(body: body, completionError: URLError(.networkConnectionLost)))
        do { _ = try await compact(); XCTFail("Expected interrupted download") }
        catch { XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost) }
    }

    func testCompactionUsesConfiguredTimeout() async throws {
        await TestURLProtocol.enqueue(.init(body: compactReply, inspect: { request in
            XCTAssertEqual(request.timeoutInterval, 7)
        }))
        _ = try await compact(configuration: .init(streamIdleTimeout: 7))
    }

    func testBase64ReferencesRestoreAndMissingAttachmentsFailBeforeHTTP() async throws {
        let image = AgentImageAttachment(mimeType: "image/png", data: Data([137, 80, 78, 71]))
        let raw: [JSONValue] = [.object(["type": .string("image_generation_call"), "result": .string(image.data.base64EncodedString())])]
        let items = try CodexResponsesImageReferences.externalize(raw)
        let context = CodexResponsesProviderState(items: items).agentProviderContext
        let backend = CodexResponsesBackend(urlSession: makeTestURLSession())
        await TestURLProtocol.enqueue(.init(body: compactReply, inspect: { request in
            let value = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(requestBodyData(for: request)))
            XCTAssertEqual(value.objectValue?["input"]?.arrayValue, raw + [.object(["type": .string("compaction_trigger")])])
        }))
        do {
            _ = try await backend.compactContext(thread: .init(id: "thread"), effectiveHistory: [], providerContext: context,
                instructions: "", tools: [], session: demoSession())
            XCTFail("Expected missing attachment")
        } catch { XCTAssertEqual((error as? AgentRuntimeError)?.code, "responses_missing_persisted_image") }
        // The queued response must still be available: the rejected call cannot reach the network.
        _ = try await backend.compactContext(thread: .init(id: "thread"),
            effectiveHistory: [.init(threadID: "thread", role: .assistant, text: "Image", images: [image])],
            providerContext: context, instructions: "", tools: [], session: demoSession())
    }

    func testLegacyResponseIDCannotReplaceClientManagedCompactionInput() async throws {
        let item: JSONValue = .object(["type": .string("reasoning"), "encrypted_content": .string("retained")])
        let context = AgentProviderContext(providerID: "openai.responses", payload: .object([
            "items": .array([item]), "previous_response_id": .string("previous")
        ]))
        await TestURLProtocol.enqueue(.init(body: compactReply, inspect: { request in
            let value = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(requestBodyData(for: request)))
            XCTAssertEqual(value.objectValue?["input"]?.arrayValue, [item, .object(["type": .string("compaction_trigger")])])
            XCTAssertNil(value.objectValue?["previous_response_id"])
        }))
        let backend = CodexResponsesBackend(urlSession: makeTestURLSession())
        _ = try await backend.compactContext(thread: .init(id: "thread"), effectiveHistory: [], providerContext: context,
            instructions: "", tools: [], session: demoSession())
    }

    func testCompactionResponseImagesStayInBlobsAndResolveAfterDatabaseReopen() async throws {
        let image = AgentImageAttachment(mimeType: "image/png", data: Data([137, 80, 78, 71]))
        let message = AgentMessage(threadID: "thread", role: .user, text: "Image summary", images: [image])
        let output = [WorkingHistoryItem.visibleMessage(message).jsonValue]
        await TestURLProtocol.enqueue(.init(body: compactReply))
        let compacted = try await CodexResponsesBackend(urlSession: makeTestURLSession()).compactContext(
            thread: .init(id: "thread"), effectiveHistory: [message], instructions: "", tools: [], session: demoSession())
        let compactedPayload = try JSONEncoder().encode(compacted.providerContext)
        let payloadText = String(decoding: compactedPayload, as: UTF8.self)
        XCTAssertFalse(payloadText.contains(image.data.base64EncodedString()))
        XCTAssertTrue(payloadText.contains("codexkit-image-ref:"))
        XCTAssertEqual(compacted.effectiveMessages.flatMap(\.images).map(\.data), [image.data])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        for adapter in ["sqlite", "realm"] {
            let url = directory.appendingPathComponent(adapter)
            let open: () throws -> any RuntimeStateStoring = {
                adapter == "sqlite" ? try SQLiteRuntimeStateStore(url: url) : try RealmRuntimeStateStore(url: url)
            }
            let store = try open()
            try await store.saveState(.init(threads: [.init(id: "thread")], contextStateByThread: ["thread": .init(
                threadID: "thread", effectiveMessages: compacted.effectiveMessages, providerContext: compacted.providerContext)]))
            let reopened = try open()
            let activation = try await reopened.loadThreadActivationState(id: "thread", policy: .init())
            await TestURLProtocol.enqueue(.init(body: compactReply, inspect: { request in
                let value = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(requestBodyData(for: request)))
                let input = try XCTUnwrap(value.objectValue?["input"]?.arrayValue)
                XCTAssertEqual(Array(input.prefix(1)), output)
                XCTAssertEqual(input.dropFirst().first?.objectValue?["type"], .string("compaction"))
                XCTAssertEqual(input.last?.objectValue?["type"], .string("compaction_trigger"))
            }))
            _ = try await CodexResponsesBackend(urlSession: makeTestURLSession()).compactContext(thread: activation.thread,
                effectiveHistory: activation.effectiveMessages, providerContext: activation.contextState?.providerContext,
                instructions: "", tools: [], session: demoSession())
        }
    }

    func testRecoveryRetriesBothStrategiesWithTheReplacementToken() async throws {
        for strategy in [AgentContextCompactionStrategy.remoteOnly, .preferRemoteThenLocal] {
            let provider = CompactionSessionProvider()
            let runtime = try runtime(provider: provider, strategy: strategy)
            let thread = try await runtime.createThread()
            await TestURLProtocol.enqueue(.init(statusCode: 401, body: Data(), inspect: { request in
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer old")
            }))
            await TestURLProtocol.enqueue(.init(body: compactReply, inspect: { request in
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer recovered")
            }))
            let result = try await runtime.compactThreadContext(id: thread.id)
            XCTAssertEqual(result.providerContext?.payload.objectValue?["items"]?.arrayValue?.last?.objectValue?["encrypted_content"], .string("Summary"))
            let recoveries = await provider.recoveries
            XCTAssertEqual(recoveries, 1)
        }
    }

    func testFailedRecoveryAndAccountReplacementNeverFallBackToLocal() async throws {
        for strategy in [AgentContextCompactionStrategy.remoteOnly, .preferRemoteThenLocal] {
            for outcome in [CompactionSessionProvider.Outcome.failure, .differentAccount, .cancelled, .success] {
                let provider = CompactionSessionProvider(outcome: outcome)
                let store = InMemoryRuntimeStateStore()
                let runtime = try runtime(provider: provider, strategy: strategy, store: store)
                let thread = try await runtime.createThread()
                let before = try await store.loadState()
                await TestURLProtocol.enqueue(.init(statusCode: 401, body: Data()))
                if outcome == .success { await TestURLProtocol.enqueue(.init(statusCode: 403, body: Data())) }
                do { _ = try await runtime.compactThreadContext(id: thread.id); XCTFail("Expected failed recovery") }
                catch {
                    if outcome == .differentAccount { XCTAssertEqual(error as? ChatGPTSessionError, .accountChanged) }
                    else if outcome == .cancelled { XCTAssertTrue(error is CancellationError) }
                    else { XCTAssertEqual((error as? AgentRuntimeError)?.code, outcome == .failure ? "refresh_failed" : "responses_compact_http_status_403") }
                }
                let after = try await store.loadState()
                XCTAssertEqual(after, before)
                let recoveries = await provider.recoveries
                XCTAssertEqual(recoveries, 1)
            }
        }
    }

    func testNonAuthenticationFailureStillPermitsConfiguredLocalFallback() async throws {
        let runtime = try runtime(provider: CompactionSessionProvider(), strategy: .preferRemoteThenLocal)
        let thread = try await runtime.createThread()
        try await runtime.appendMessage(.init(threadID: thread.id, role: .user, text: "Retain me"))
        await TestURLProtocol.enqueue(.init(statusCode: 503, body: Data()))
        let result = try await runtime.compactThreadContext(id: thread.id)
        XCTAssertEqual(result.effectiveMessages.first?.text, "Retain me")
        XCTAssertEqual(result.generation, 1)
    }

    func testCancellationDuringResponseStopsDownload() async throws {
        let events = CompactionDownloadEvents()
        PausedCompactionProtocol.events = events
        defer { PausedCompactionProtocol.events = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PausedCompactionProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let backend = CodexResponsesBackend(urlSession: session)
        let task = Task {
            try await backend.compactContext(thread: .init(id: "thread"), effectiveHistory: [],
                instructions: "", tools: [], session: demoSession())
        }
        await fulfillment(of: [events.started], timeout: 5)
        task.cancel()
        await fulfillment(of: [events.stopped], timeout: 5)
        do { _ = try await task.value; XCTFail("Expected cancelled download") }
        catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
    }

    private func compact(configuration: CodexResponsesBackendConfiguration = .init(requestRetryPolicy: .disabled)) async throws -> AgentCompactionResult {
        try await CodexResponsesBackend(configuration: configuration, urlSession: makeTestURLSession()).compactContext(
            thread: .init(id: "thread"), effectiveHistory: [], instructions: "", tools: [], session: demoSession())
    }

    private func runtime(provider: CompactionSessionProvider, strategy: AgentContextCompactionStrategy,
        store: any RuntimeStateStoring = InMemoryRuntimeStateStore()) throws -> AgentRuntime {
        try .init(configuration: .init(sessionProvider: provider, backend: CodexResponsesBackend(configuration: .init(requestRetryPolicy: .disabled), urlSession: makeTestURLSession()),
            approvalPresenter: AutoApprovalPresenter(), stateStore: store,
            contextCompaction: .init(isEnabled: true, mode: .manual, strategy: strategy)))
    }

    private var compactReply: Data {
        streamedCompactionReply()
    }
}

private actor CompactionSessionProvider: AgentSessionProviding {
    enum Outcome { case success, failure, differentAccount, cancelled }
    let outcome: Outcome
    var recoveries = 0
    init(outcome: Outcome = .success) { self.outcome = outcome }
    func currentSession() async -> ChatGPTSession? { demoSession(accessToken: "old") }
    func recoverUnauthorizedSession(previousAccessToken: String?) async throws -> ChatGPTSession {
        recoveries += 1
        XCTAssertEqual(previousAccessToken, "old")
        if outcome == .failure { throw AgentRuntimeError(code: "refresh_failed", message: "Refresh failed") }
        if outcome == .cancelled { throw CancellationError() }
        var result = demoSession(accessToken: "recovered")
        if outcome == .differentAccount { result.account.id = "another-account" }
        return result
    }
}

private final class CompactionDownloadEvents: Sendable {
    let started = XCTestExpectation(description: "Response bytes started")
    let stopped = XCTestExpectation(description: "Download cancelled")
}

private final class PausedCompactionProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var storedEvents: CompactionDownloadEvents?
    static var events: CompactionDownloadEvents? {
        get { lock.withLock { storedEvents } }
        set { lock.withLock { storedEvents = newValue } }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"output":["#.utf8))
        Self.events?.started.fulfill()
    }
    override func stopLoading() { Self.events?.stopped.fulfill() }
}
