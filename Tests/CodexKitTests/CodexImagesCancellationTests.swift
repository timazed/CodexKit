import CodexKit
import XCTest

final class CodexImagesCancellationTests: XCTestCase {
    func testAlreadyCancelledRequestDoesNotTransmit() async throws {
        let events = CodexImageEvents()
        PausedCodexImageProtocol.events = events
        defer { PausedCodexImageProtocol.events = nil }
        let urlSession = makeSession()
        defer { urlSession.invalidateAndCancel() }
        let client = AgentImageGenerationClient(urlSession: urlSession)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.generate(prompt: "Draw", session: demoSession())
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(events.requestCount, 0)
    }

    func testCancellationBeforeHeadersDuringJSONAndAfterCompleteJSONBeforeEOFStopsRequest() async throws {
        for mode in [CodexImageEvents.Mode.beforeHeaders, .provisionalImage, .httpError, .completed] {
            let events = CodexImageEvents(mode: mode)
            PausedCodexImageProtocol.events = events
            let urlSession = makeSession()
            let client = AgentImageGenerationClient(urlSession: urlSession)
            let task = Task { try await client.generate(prompt: "Draw", session: demoSession()) }
            await fulfillment(of: [events.started], timeout: 5)
            task.cancel()
            await fulfillment(of: [events.stopped], timeout: 5)
            do { _ = try await task.value; XCTFail("Cancellation must not return a provisional image") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(events.requestCount, 1)
            urlSession.invalidateAndCancel()
            PausedCodexImageProtocol.events = nil
        }
    }

    func testConnectionFailureAfterImageJSONNeverReturnsAnImageOrRetries() async throws {
        let events = CodexImageEvents(mode: .disconnected)
        PausedCodexImageProtocol.events = events
        defer { PausedCodexImageProtocol.events = nil }
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        do {
            _ = try await AgentImageGenerationClient(urlSession: session).generate(prompt: "Draw", session: demoSession())
            XCTFail("A failed HTTP body must not commit otherwise valid image JSON")
        } catch let error as AgentRuntimeError {
            XCTAssertEqual(error.knownCode, .imageGenerationInvalidResponse)
        }
        XCTAssertEqual(events.requestCount, 1)
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PausedCodexImageProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class CodexImageEvents: @unchecked Sendable {
    enum Mode { case beforeHeaders, provisionalImage, httpError, completed, disconnected }
    let mode: Mode
    let started = XCTestExpectation(description: "Request started")
    let stopped = XCTestExpectation(description: "Network task stopped")
    private let lock = NSLock()
    private var count = 0
    var requestCount: Int { lock.withLock { count } }
    func recordRequest() { lock.withLock { count += 1 } }
    init(mode: Mode = .beforeHeaders) { self.mode = mode }
}

private final class PausedCodexImageProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var storedEvents: CodexImageEvents?
    static var events: CodexImageEvents? {
        get { lock.withLock { storedEvents } }
        set { lock.withLock { storedEvents = newValue } }
    }
    private var currentEvents: CodexImageEvents?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let events = Self.events else { return }
        currentEvents = events
        events.recordRequest()
        if events.mode != .beforeHeaders {
            let response = HTTPURLResponse(url: request.url!, statusCode: events.mode == .httpError ? 400 : 200,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            let body: Data
            switch events.mode {
            case .completed, .disconnected:
                body = try! codexImageJSON()
            case .httpError: body = Data(#"{"error":{"message":"unfinished"#.utf8)
            default: body = Data(#"{"created":1,"data":[{"b64_json":"unfinished"#.utf8)
            }
            for offset in stride(from: 0, to: body.count, by: 7) {
                client?.urlProtocol(self, didLoad: body.subdata(in: offset..<min(offset + 7, body.count)))
            }
        }
        events.started.fulfill()
        if events.mode == .disconnected {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
        }
        // Deliberately leave the response open: cancellation must release it, even when complete JSON arrived.
    }
    override func stopLoading() { currentEvents?.stopped.fulfill() }
}
