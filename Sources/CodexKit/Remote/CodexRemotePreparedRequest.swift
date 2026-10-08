import CryptoKit
import Foundation

/// Exact, already-prepared text or JSON request bytes and their routing metadata.
/// This packet never contains completion push preferences or credentials.
public struct CodexRemotePreparedResponse: Codable, Hashable, Sendable {
    public let bodyBase64: String
    public let sha256: String
    public let sessionID: String
    public let clientRequestID: String
    public let originator: String

    public init(body: Data, sha256: String, sessionID: String, clientRequestID: String, originator: String) {
        bodyBase64 = body.base64EncodedString()
        self.sha256 = sha256
        self.sessionID = sessionID
        self.clientRequestID = clientRequestID
        self.originator = originator
    }

    private enum CodingKeys: String, CodingKey {
        case bodyBase64, sha256, originator
        case sessionID = "sessionId"
        case clientRequestID = "clientRequestId"
    }

    func validate() throws {
        try CodexRemotePreparedValidation.validate(bodyBase64: bodyBase64, sha256: sha256,
            routing: [sessionID, clientRequestID, originator])
    }
}

/// Exact, already-prepared image generation/editing request bytes.
/// The configured middleware determines which image actions it supports.
public struct CodexRemotePreparedImage: Codable, Hashable, Sendable {
    public enum Action: String, Codable, Hashable, Sendable { case generate, edit }

    public let bodyBase64: String
    public let sha256: String
    public let clientRequestID: String
    public let imageTurnID: String
    public let originator: String
    public let action: Action

    public init(body: Data, sha256: String, clientRequestID: String, imageTurnID: String,
                originator: String, action: Action = .generate) {
        bodyBase64 = body.base64EncodedString()
        self.sha256 = sha256
        self.clientRequestID = clientRequestID
        self.imageTurnID = imageTurnID
        self.originator = originator
        self.action = action
    }

    private enum CodingKeys: String, CodingKey {
        case bodyBase64, sha256, originator, action
        case clientRequestID = "clientRequestId"
        case imageTurnID = "imageTurnId"
    }

    func validate() throws {
        try CodexRemotePreparedValidation.validate(bodyBase64: bodyBase64, sha256: sha256,
            routing: [clientRequestID, imageTurnID, originator])
    }
}

private enum CodexRemotePreparedValidation {
    static func validate(bodyBase64: String, sha256: String, routing: [String]) throws {
        guard routing.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1_024 &&
            $0.utf8.allSatisfy({ (0x21...0x7e).contains($0) }) }),
            let body = Data(base64Encoded: bodyBase64), !body.isEmpty,
            body.base64EncodedString() == bodyBase64,
            SHA256.hash(data: body).map({ String(format: "%02x", $0) }).joined() == sha256 else {
            throw CodexRemoteExecutionError.invalidPreparedRequest
        }
    }
}
