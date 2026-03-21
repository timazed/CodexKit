import Foundation

public struct RequestRetryPolicy: Sendable, Equatable {
    public let maxAttempts: Int
    public let initialBackoff: TimeInterval
    public let maxBackoff: TimeInterval
    public let jitterFactor: Double
    public let retryableHTTPStatusCodes: Set<Int>
    public let retryableURLErrorCodes: Set<Int>

    public init(
        maxAttempts: Int = 3,
        initialBackoff: TimeInterval = 0.5,
        maxBackoff: TimeInterval = 4,
        jitterFactor: Double = 0.2,
        retryableHTTPStatusCodes: Set<Int> = [408, 409, 425, 429, 500, 502, 503, 504],
        retryableURLErrorCodes: Set<Int> = [
            URLError.timedOut.rawValue,
            URLError.cannotFindHost.rawValue,
            URLError.cannotConnectToHost.rawValue,
            URLError.networkConnectionLost.rawValue,
            URLError.dnsLookupFailed.rawValue,
            URLError.notConnectedToInternet.rawValue,
            URLError.resourceUnavailable.rawValue,
            URLError.cannotLoadFromNetwork.rawValue,
            URLError.internationalRoamingOff.rawValue,
        ]
    ) {
        self.maxAttempts = max(1, maxAttempts)
        self.initialBackoff = max(0, initialBackoff)
        self.maxBackoff = max(self.initialBackoff, maxBackoff)
        self.jitterFactor = min(max(0, jitterFactor), 1)
        self.retryableHTTPStatusCodes = retryableHTTPStatusCodes
        self.retryableURLErrorCodes = retryableURLErrorCodes
    }

    public static let `default` = RequestRetryPolicy()
    public static let disabled = RequestRetryPolicy(maxAttempts: 1)
}

extension RequestRetryPolicy {
    func delayBeforeRetry(attempt: Int) -> TimeInterval {
        let exponential = initialBackoff * pow(2, Double(max(0, attempt - 1)))
        let capped = min(maxBackoff, exponential)
        guard jitterFactor > 0 else {
            return capped
        }

        let jitterRange = capped * jitterFactor
        let jittered = capped + Double.random(in: -jitterRange ... jitterRange)
        return max(0, jittered)
    }
}
