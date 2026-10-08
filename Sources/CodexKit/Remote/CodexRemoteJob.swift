import Foundation

/// Middleware job metadata returned by submission and status requests.
public struct CodexRemoteJob: Codable, Hashable, Sendable {
    public let jobID: String
    public let status: String
    public let completionPush: CodexCompletionPush
    public let deviceID: String?
    public let kind: String?
    public let createdAt: String?
    public let updatedAt: String?
    public let expiresAt: TimeInterval?
    public let failure: Failure?

    public struct Failure: Codable, Hashable, Sendable {
        public let code: String
        public let outcome: String
        public let message: String?
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        jobID = try values.decode(String.self, forKey: .jobID)
        status = try values.decode(String.self, forKey: .status)
        completionPush = try values.decodeIfPresent(CodexCompletionPush.self, forKey: .completionPush) ?? .silent
        deviceID = try values.decodeIfPresent(String.self, forKey: .deviceID)
        kind = try values.decodeIfPresent(String.self, forKey: .kind)
        createdAt = try values.decodeIfPresent(String.self, forKey: .createdAt)
        updatedAt = try values.decodeIfPresent(String.self, forKey: .updatedAt)
        expiresAt = try values.decodeIfPresent(TimeInterval.self, forKey: .expiresAt)
        failure = try values.decodeIfPresent(Failure.self, forKey: .failure)
    }

    private enum CodingKeys: String, CodingKey {
        case jobID = "jobId"
        case deviceID = "deviceId"
        case status, completionPush, kind, createdAt, updatedAt, expiresAt, failure
    }
}
