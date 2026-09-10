import Foundation

public struct AgentHTTPFailure: Codable, Hashable, Sendable {
    public let statusCode: Int
    public let providerCode: String?
    public let providerType: String?
    public let requestID: String?
    public let retryAfter: TimeInterval?

    public init(statusCode: Int, providerCode: String? = nil, providerType: String? = nil,
        requestID: String? = nil, retryAfter: TimeInterval? = nil) {
        self.statusCode = statusCode
        self.providerCode = providerCode
        self.providerType = providerType
        self.requestID = requestID
        self.retryAfter = retryAfter.flatMap { $0.isFinite && $0 >= 0 ? min($0, 86_400) : nil }
    }
}

public enum AgentRetrySafety: String, Codable, Hashable, Sendable {
    case beforeOutput
    case outputAlreadyEmitted
}

public struct AgentRetryInformation: Codable, Hashable, Sendable {
    public let attempt: Int
    public let maximumAttempts: Int
    public let isRetryable: Bool
    public let safety: AgentRetrySafety

    public init(attempt: Int, maximumAttempts: Int, isRetryable: Bool, safety: AgentRetrySafety) {
        self.attempt = attempt
        self.maximumAttempts = maximumAttempts
        self.isRetryable = isRetryable
        self.safety = safety
    }
}

extension AgentHTTPFailure {
    init(response: HTTPURLResponse, body: Data = Data(), now: Date = Date()) {
        let value = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let error = (value?["error"] as? [String: Any]) ?? value
        self.init(statusCode: response.statusCode,
            providerCode: (error?["code"] as? String).map { String($0.prefix(1_024)) },
            providerType: (error?["type"] as? String).map { String($0.prefix(1_024)) },
            requestID: (response.value(forHTTPHeaderField: "x-request-id")
                ?? response.value(forHTTPHeaderField: "request-id")).map { String($0.prefix(1_024)) },
            retryAfter: Self.retryAfter(response.value(forHTTPHeaderField: "Retry-After"), now: now))
    }

    static func retryAfter(_ value: String?, now: Date) -> TimeInterval? {
        guard let value else { return nil }
        if let seconds = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return seconds.isFinite && seconds >= 0 ? min(seconds, 86_400) : nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        return formatter.date(from: value).map { min(86_400, max(0, $0.timeIntervalSince(now))) }
    }
}

extension AgentRuntimeError {
    static func httpFailure(response: HTTPURLResponse, body: Data = Data(), prefix: String, message: String) -> Self {
        let unauthorized = response.statusCode == 401
        return .init(code: unauthorized ? "unauthorized" : "\(prefix)_http_status_\(response.statusCode)",
            message: message, http: .init(response: response, body: body))
    }

    func withRetryInformation(_ information: AgentRetryInformation) -> Self {
        .init(code: code, message: message, http: http, retry: information, interruption: interruption)
    }
}
