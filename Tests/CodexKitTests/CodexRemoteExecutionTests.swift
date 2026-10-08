import CodexKit
import CryptoKit
import Foundation
import XCTest

final class CodexRemoteExecutionTests: XCTestCase {
    override func setUp() async throws { await TestURLProtocol.reset() }
    override func tearDown() async throws { await TestURLProtocol.reset() }

    func testExplicitSilentRegularAndOmittedPreferencesForTextJSONAndImages() async throws {
        for kind in RequestKind.allCases {
            for preference: CodexCompletionPush? in [nil, .silent, .regular] {
                let execution = makeExecution(kind, preference: preference)
                let expected = preference ?? .silent
                let originalBody = kind.body
                await TestURLProtocol.enqueue(.init(statusCode: 202, body: jobEnvelope(expected), inspect: { request in
                    XCTAssertEqual(request.url?.path, kind == .image ? "/api/codex/images" : "/api/codex")
                    XCTAssertEqual(request.httpMethod, "POST")
                    XCTAssertEqual(request.value(forHTTPHeaderField: "x-device-id"), "fixture-device")
                    XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
                    let envelope = try submission(request)
                    XCTAssertEqual(Set(envelope.keys), ["preparedRequest", "authentication", "completionPush"])
                    XCTAssertEqual(envelope["completionPush"] as? String, expected.rawValue)
                    let auth = try XCTUnwrap(envelope["authentication"] as? [String: String])
                    XCTAssertEqual(auth, ["accessToken": "fixture-token", "accountId": "fixture-account"])
                    let prepared = try XCTUnwrap(envelope["preparedRequest"] as? [String: String])
                    let body = try XCTUnwrap(prepared["bodyBase64"].flatMap { Data(base64Encoded: $0) })
                    XCTAssertEqual(body, originalBody)
                    XCTAssertEqual(prepared["sha256"], digest(originalBody))
                    XCTAssertEqual(prepared["clientRequestId"], "fixture-request")
                    XCTAssertNil(prepared["completionPush"])
                    XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("completionPush"))
                    if kind == .image {
                        XCTAssertEqual(prepared["action"], "generate")
                        XCTAssertEqual(prepared["imageTurnId"], "fixture-request")
                    } else {
                        XCTAssertEqual(prepared["sessionId"], "fixture-session")
                    }
                }))
                let result = try await makeClient().execute(remoteExecution: execution, authentication: credentials)
                XCTAssertEqual(execution.completionPush, expected)
                XCTAssertEqual(result.completionPush, expected)
                XCTAssertEqual(result.jobID, "fixture-job")
            }
        }
    }

    func testSubmissionRetriesPreservePreferenceIdentityDigestAndEntireEnvelope() async throws {
        for kind in RequestKind.allCases {
            for preference: CodexCompletionPush? in [nil, .silent, .regular] {
                let execution = makeExecution(kind, preference: preference)
                // Persist only the prepared request and options; restore before submitting.
                let saved = try JSONEncoder().encode(execution)
                XCTAssertFalse(String(decoding: saved, as: UTF8.self).contains("fixture-token"))
                let restored = try JSONDecoder().decode(CodexRemoteExecution.self, from: saved)
                XCTAssertEqual(restored, execution)
                let requests = RequestLog()
                await TestURLProtocol.enqueue(.init(statusCode: 503, body: Data(), inspect: requests.record))
                await TestURLProtocol.enqueue(.init(body: Data(), error: URLError(.networkConnectionLost), inspect: requests.record))
                await TestURLProtocol.enqueue(.init(statusCode: 202, body: jobEnvelope(preference ?? .silent), inspect: requests.record))
                let job = try await makeClient().execute(remoteExecution: restored, authentication: credentials)
                XCTAssertEqual(job.completionPush, preference ?? .silent)
                XCTAssertEqual(requests.bodies.count, 3)
                XCTAssertEqual(Set(requests.bodies).count, 1, "Every retry must send the identical envelope")
                let first = try XCTUnwrap(requests.bodies.first)
                let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: first) as? [String: Any])
                XCTAssertEqual(envelope["completionPush"] as? String, (preference ?? .silent).rawValue)
                let prepared = try XCTUnwrap(envelope["preparedRequest"] as? [String: String])
                XCTAssertEqual(prepared["sha256"], digest(kind.body))
                XCTAssertEqual(prepared["clientRequestId"], "fixture-request")
                XCTAssertEqual(prepared["bodyBase64"], kind.body.base64EncodedString())
            }
        }
    }

    func testConflictNeverRetriesEvenWhenSharedRetryPolicyIncludes409() async throws {
        let requests = RequestLog()
        await TestURLProtocol.enqueue(.init(statusCode: 409, body: Data(), inspect: requests.record))
        await TestURLProtocol.enqueue(.init(body: jobEnvelope(.regular), inspect: requests.record))
        do {
            _ = try await makeClient().execute(remoteExecution: makeExecution(.text, preference: .regular), authentication: credentials)
            XCTFail("Conflicting request identity must fail")
        } catch let CodexRemoteExecutionError.http(failure) {
            XCTAssertEqual(failure.statusCode, 409)
        }
        XCTAssertEqual(requests.bodies.count, 1)
    }

    func testJobStatusDecodesExplicitAndLegacyPreferences() async throws {
        for preference in [nil, "silent", "regular"] {
            var metadata: [String: Any] = ["jobId": "fixture-job", "status": "succeeded", "deviceId": "fixture-device",
                "kind": "image", "createdAt": "2026-10-08T00:00:00Z", "updatedAt": "2026-10-08T00:01:00Z", "expiresAt": 1_800_000_000]
            if let preference { metadata["completionPush"] = preference }
            await TestURLProtocol.enqueue(.init(body: try JSONSerialization.data(withJSONObject: ["data": metadata]), inspect: { request in
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(request.url?.path, "/api/codex/fixture-job")
                XCTAssertNil(request.httpBody)
            }))
            let job = try await makeClient().job(id: "fixture-job")
            XCTAssertEqual(job.completionPush.rawValue, preference ?? "silent")
            XCTAssertEqual(job.deviceID, "fixture-device")
            XCTAssertEqual(job.kind, "image")
            XCTAssertEqual(job.expiresAt, 1_800_000_000)
            XCTAssertEqual(try JSONDecoder().decode(CodexRemoteJob.self, from: JSONEncoder().encode(job)), job)
        }
    }

    func testLegacyExecutionDefaultsToSilentAndUnknownPreferencesFailDecoding() throws {
        for kind in RequestKind.allCases {
            let original = makeExecution(kind, preference: .regular)
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
            json.removeValue(forKey: "completionPush")
            let legacy = try JSONDecoder().decode(CodexRemoteExecution.self, from: JSONSerialization.data(withJSONObject: json))
            XCTAssertEqual(legacy.completionPush, .silent)
            XCTAssertEqual(legacy.preparedRequest, original.preparedRequest)
            json["completionPush"] = "unknown"
            XCTAssertThrowsError(try JSONDecoder().decode(CodexRemoteExecution.self, from: JSONSerialization.data(withJSONObject: json)))
        }
        XCTAssertThrowsError(try JSONDecoder().decode(CodexRemoteJob.self,
            from: Data(#"{"jobId":"job","status":"queued","completionPush":"unknown"}"#.utf8)))
    }

    func testLegacySubmissionReplyDefaultsToSilentAndFailureMetadataDecodes() async throws {
        await TestURLProtocol.enqueue(.init(statusCode: 202,
            body: Data(#"{"data":{"jobId":"legacy","status":"failed","failure":{"code":"fixture_failure","outcome":"not_started"}}}"#.utf8)))
        let job = try await makeClient().execute(remoteExecution: makeExecution(.json), authentication: credentials)
        XCTAssertEqual(job.completionPush, .silent)
        XCTAssertEqual(job.failure?.code, "fixture_failure")
        XCTAssertEqual(job.failure?.outcome, "not_started")
    }

    func testInvalidDigestFailsBeforeSendingAndNeverRewritesPreparedBytes() async throws {
        let prepared = CodexRemotePreparedResponse(body: RequestKind.text.body, sha256: String(repeating: "0", count: 64),
            sessionID: "session", clientRequestID: "request", originator: "codex_cli_rs")
        do {
            _ = try await makeClient().execute(remoteExecution: .init(preparedRequest: .response(prepared)), authentication: credentials)
            XCTFail("A mismatched digest must not be silently recalculated")
        } catch let error as CodexRemoteExecutionError { XCTAssertEqual(error, .invalidPreparedRequest) }
    }

    func testCancelledSubmissionDoesNotSendOrRetry() async throws {
        let client = try makeClient()
        let execution = makeExecution(.text, preference: .regular)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.execute(remoteExecution: execution, authentication: credentials)
        }
        do { _ = try await task.value; XCTFail("Cancellation must propagate") }
        catch is CancellationError { }
    }

    func testImageEditUsesTheSameEnvelopePreference() async throws {
        let body = RequestKind.image.body
        let prepared = CodexRemotePreparedImage(body: body, sha256: digest(body), clientRequestID: "edit-request",
            imageTurnID: "edit-turn", originator: "codex_cli_rs", action: .edit)
        await TestURLProtocol.enqueue(.init(body: jobEnvelope(.regular), inspect: { request in
            let json = try submission(request)
            XCTAssertEqual(json["completionPush"] as? String, "regular")
            XCTAssertEqual((json["preparedRequest"] as? [String: String])?["action"], "edit")
        }))
        _ = try await makeClient().execute(remoteExecution: .init(preparedRequest: .image(prepared), completionPush: .regular),
            authentication: credentials)
    }
}

private let credentials = CodexRemoteAuthentication(accessToken: "fixture-token", accountID: "fixture-account")

private enum RequestKind: CaseIterable, Sendable {
    case text, json, image
    var body: Data {
        switch self {
        case .text: Data("{ \"text\": {\"format\": {\"type\": \"text\"}}, \"input\": \"fixture\" }\n".utf8)
        case .json: Data("{ \"text\": {\"format\": {\"type\": \"json_schema\", \"schema\": {\"type\": \"object\"}}} }\n".utf8)
        case .image: Data("{ \"prompt\": \"fixture\", \"background\": \"opaque\" }\n".utf8)
        }
    }
}

private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func makeExecution(_ kind: RequestKind, preference: CodexCompletionPush? = nil) -> CodexRemoteExecution {
    let prepared: CodexRemoteExecution.PreparedRequest
    if kind == .image {
        prepared = .image(.init(body: kind.body, sha256: digest(kind.body), clientRequestID: "fixture-request",
            imageTurnID: "fixture-request", originator: "codex_cli_rs"))
    } else {
        prepared = .response(.init(body: kind.body, sha256: digest(kind.body), sessionID: "fixture-session",
            clientRequestID: "fixture-request", originator: "codex_cli_rs"))
    }
    if let preference { return .init(preparedRequest: prepared, completionPush: preference) }
    return .init(preparedRequest: prepared)
}

private func makeClient() throws -> CodexRemoteExecutionClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [TestURLProtocol.self]
    return try .init(baseURL: URL(string: "https://middleware.invalid/api")!, headers: ["x-device-id": "fixture-device"],
        retryPolicy: .init(initialBackoff: 0, maxBackoff: 0), sessionConfiguration: configuration)
}

private func jobEnvelope(_ preference: CodexCompletionPush) -> Data {
    Data("{\"data\":{\"jobId\":\"fixture-job\",\"status\":\"queued\",\"completionPush\":\"\(preference.rawValue)\"}}".utf8)
}

private func submission(_ request: URLRequest) throws -> [String: Any] {
    let data = try XCTUnwrap(requestBodyData(for: request))
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Data] = []
    var bodies: [Data] { lock.withLock { storage } }
    func record(_ request: URLRequest) throws {
        let data = try XCTUnwrap(requestBodyData(for: request))
        lock.withLock { storage.append(data) }
    }
}
