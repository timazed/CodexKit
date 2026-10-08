#if DEBUG
import CodexKit
import CryptoKit
import Foundation

enum RemoteDemoKind: String, CaseIterable, Identifiable, Sendable {
    case text = "Text", json = "JSON", image = "Image", imageEdit = "Image edit"
    var id: Self { self }
}

enum RemoteDemoPush: String, CaseIterable, Identifiable, Sendable {
    case defaultSilent = "Default (silent)", silent = "Silent", regular = "Regular"
    var id: Self { self }
    var resolved: CodexCompletionPush { self == .regular ? .regular : .silent }
    func execution(_ prepared: CodexRemoteExecution.PreparedRequest) -> CodexRemoteExecution {
        if self == .defaultSilent { return .init(preparedRequest: prepared) }
        return .init(preparedRequest: prepared, completionPush: resolved)
    }
}

struct RemoteDemoScenario: Sendable {
    let kind: RemoteDemoKind
    let push: RemoteDemoPush
    var retry = false
    var legacyMetadata = false
}

struct RemoteDemoResult: Identifiable, Sendable {
    let id: String
    let kind: RemoteDemoKind
    let push: RemoteDemoPush
    let text: String
    let image: Data?
    let submissions: Int
}

struct RemoteDemoQueue: Decodable, Sendable {
    struct Job: Decodable, Sendable { let jobId: String; let completionPush: CodexCompletionPush; let providerCalls: Int }
    struct Submission: Decodable, Sendable {
        let jobId: String
        let clientRequestId: String
        let completionPush: CodexCompletionPush
        let envelopeSHA256: String
        let sha256: String
        let bodySHA256: String
        let conflict: Bool
    }
    struct Delivery: Decodable, Sendable {
        let simulated: Bool
        let jobIds: [String]
        let completionPush: CodexCompletionPush
    }
    let jobs: [Job]
    let submissions: [Submission]
    let deliveries: [Delivery]
}

struct RemoteDemoReport: Sendable {
    let results: [RemoteDemoResult]
    let checks: [String]
}

struct RemoteDemoFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Demo-owned preparation of supported tool-free packets. The remote SDK owns
/// envelope serialization, preference defaults, integrity checks and HTTP retries.
enum RemoteDemoPreparedRequest {
    static let referencePNG = "iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAYAAAD0In+KAAAAD0lEQVR4nGP4z8DwHwgbABB5A359Y87XAAAAAElFTkSuQmCC"

    static func make(kind: RemoteDemoKind, prompt: String, model: String) throws -> CodexRemoteExecution.PreparedRequest {
        let requestID = UUID().uuidString
        let body: Data
        if kind == .image || kind == .imageEdit {
            var value: [String: Any] = ["prompt": prompt, "model": "gpt-image-2", "quality": "auto",
                "size": "auto", "background": "transparent"]
            if kind == .imageEdit { value["images"] = [["image_url": "data:image/png;base64,\(referencePNG)"]] }
            body = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            return .image(.init(body: body, sha256: digest(body), clientRequestID: requestID,
                imageTurnID: requestID, originator: "codex_cli_rs", action: kind == .image ? .generate : .edit))
        }
        let format: [String: Any] = kind == .text ? ["type": "text"] : ["type": "json_schema", "name": "remote-demo",
            "strict": true, "schema": ["type": "object", "properties": ["message": ["type": "string"]],
                "required": ["message"], "additionalProperties": false]]
        body = try JSONSerialization.data(withJSONObject: [
            "model": model, "instructions": "Return a short confirmation of the requested demonstration.",
            "input": [["type": "message", "role": "user", "content": [["type": "input_text", "text": prompt]]]],
            "tools": [], "tool_choice": "none", "store": false, "stream": true,
            "reasoning": ["effort": "low"], "text": ["format": format],
        ], options: [.sortedKeys])
        return .response(.init(body: body, sha256: digest(body), sessionID: requestID,
            clientRequestID: requestID, originator: "codex_cli_rs"))
    }

    private static func digest(_ body: Data) -> String {
        SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
    }
}
#endif
