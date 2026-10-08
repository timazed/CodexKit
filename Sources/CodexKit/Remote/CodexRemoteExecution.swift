import Foundation

/// Requested delivery style for the middleware's completion push.
/// The middleware owns device batching and delivery; regular wins in a mixed batch.
public enum CodexCompletionPush: String, Codable, Hashable, Sendable {
    case silent
    case regular
}

/// A prepared submission and its immutable, per-request middleware options.
/// Retain this value (or persist it with Codable) for subsequent submission retries.
/// Credentials are supplied separately when submitting and are never stored here.
public struct CodexRemoteExecution: Codable, Hashable, Sendable {
    public enum PreparedRequest: Codable, Hashable, Sendable {
        case response(CodexRemotePreparedResponse)
        case image(CodexRemotePreparedImage)
    }

    public let preparedRequest: PreparedRequest
    public let completionPush: CodexCompletionPush

    public init(preparedRequest: PreparedRequest, completionPush: CodexCompletionPush = .silent) {
        self.preparedRequest = preparedRequest
        self.completionPush = completionPush
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        preparedRequest = try values.decode(PreparedRequest.self, forKey: .preparedRequest)
        completionPush = try values.decodeIfPresent(CodexCompletionPush.self, forKey: .completionPush) ?? .silent
    }

    private enum CodingKeys: String, CodingKey { case preparedRequest, completionPush }

    var path: String {
        switch preparedRequest {
        case .response: "codex"
        case .image: "codex/images"
        }
    }

    func submission(authentication: CodexRemoteAuthentication) throws -> Data {
        // Encode the envelope once before retrying. The provider body is only base64 encoded.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        switch preparedRequest {
        case let .response(request):
            try request.validate()
            return try encoder.encode(Submission(preparedRequest: request,
                authentication: authentication, completionPush: completionPush))
        case let .image(request):
            try request.validate()
            return try encoder.encode(Submission(preparedRequest: request,
                authentication: authentication, completionPush: completionPush))
        }
    }

    private struct Submission<Prepared: Encodable>: Encodable {
        let preparedRequest: Prepared
        let authentication: CodexRemoteAuthentication
        let completionPush: CodexCompletionPush
    }
}

/// Provider credentials for one middleware submission. The client does not refresh them.
public struct CodexRemoteAuthentication: Encodable, Sendable {
    public let accessToken: String
    public let accountID: String

    public init(accessToken: String, accountID: String) {
        self.accessToken = accessToken
        self.accountID = accountID
    }

    public init(session: ChatGPTSession) {
        self.init(accessToken: session.accessToken, accountID: session.account.id)
    }

    private enum CodingKeys: String, CodingKey {
        case accessToken
        case accountID = "accountId"
    }
}
