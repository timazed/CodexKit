import Foundation

/// Diagnostic state of one Responses HTTP attempt. IDs and cursors do not imply remote resumability.
public struct AgentResponseInterruption: Codable, Hashable, Sendable {
    public enum Outcome: String, Codable, Hashable, Sendable {
        case disconnected, providerFailed, providerIncomplete, requestRejected, cancelled, other
    }

    public let outcome: Outcome
    public let clientRequestID: String?
    public let requestID: String?
    public let responseID: String?
    public let lastSequenceNumber: Int?
    public let hasOutput: Bool
    /// Conservative: a tool was requested, possibly before its result was received.
    public let hasToolActivity: Bool
    public let providerCompleted: Bool
    public let transportErrorDomain: String?
    public let transportErrorCode: Int?

    public init(outcome: Outcome, clientRequestID: String? = nil, requestID: String? = nil,
        responseID: String? = nil, lastSequenceNumber: Int? = nil, hasOutput: Bool = false,
        hasToolActivity: Bool = false, providerCompleted: Bool = false,
        transportErrorDomain: String? = nil, transportErrorCode: Int? = nil) {
        self.outcome = outcome
        self.clientRequestID = clientRequestID
        self.requestID = requestID
        self.responseID = responseID
        self.lastSequenceNumber = lastSequenceNumber
        self.hasOutput = hasOutput
        self.hasToolActivity = hasToolActivity
        self.providerCompleted = providerCompleted
        self.transportErrorDomain = transportErrorDomain
        self.transportErrorCode = transportErrorCode
    }
}

struct ResponsesAttemptObservation {
    var responseID: String?
    var lastSequenceNumber: Int?
    var hasOutput = false
    var hasToolActivity = false
    var providerCompleted = false

    mutating func observe(_ event: CodexResponsesStreamEvent) {
        if let sequence = event.sequenceNumber { lastSequenceNumber = sequence }
        switch event.kind {
        case let .responseCreated(id): responseID = id ?? responseID
        case let .failed(_, id): responseID = id ?? responseID
        case let .completed(_, id): responseID = id ?? responseID; providerCompleted = true
        case .assistantTextDelta, .structuredOutputPartial, .structuredOutputCommitted:
            hasOutput = true
        case let .progress(progress):
            hasOutput = true
            if case .webSearch = progress { hasToolActivity = true }
        case let .outputItem(item, _):
            hasOutput = true
            if case .functionCall = item.kind { hasToolActivity = true }
            if case .imageGenerationCall = item.kind { hasToolActivity = true }
            if item.type == .webSearchCall { hasToolActivity = true }
        default: break
        }
    }

    func failure(_ error: Error, clientRequestID: String?, requestID: String?) -> AgentRuntimeError {
        let original = error as? AgentRuntimeError
        let transport = Self.transportError(error)
        let outcome: AgentResponseInterruption.Outcome
        switch original?.knownCode {
        case .responsesStreamDisconnected: outcome = .disconnected
        case .responsesStreamFailed: outcome = .providerFailed
        case .responsesStreamIncomplete: outcome = .providerIncomplete
        default:
            if error is CancellationError || transport?.code == URLError.cancelled.rawValue { outcome = .cancelled }
            else if transport != nil { outcome = .disconnected }
            else if original?.http != nil { outcome = .requestRejected }
            else { outcome = .other }
        }
        return .init(code: original?.code ?? (transport == nil ? AgentRuntimeErrorCode.responsesStreamError.rawValue : AgentRuntimeErrorCode.responsesTransportError.rawValue),
            message: original?.message ?? error.localizedDescription, http: original?.http, retry: original?.retry,
            interruption: .init(outcome: outcome, clientRequestID: clientRequestID, requestID: requestID,
                responseID: responseID, lastSequenceNumber: lastSequenceNumber, hasOutput: hasOutput,
                hasToolActivity: hasToolActivity, providerCompleted: providerCompleted,
                transportErrorDomain: transport?.domain, transportErrorCode: transport?.code))
    }

    private static func transportError(_ error: Error, depth: Int = 0) -> NSError? {
        let value = error as NSError
        if value.domain == NSURLErrorDomain { return value }
        guard depth < 4, let underlying = value.userInfo[NSUnderlyingErrorKey] as? Error else { return nil }
        return transportError(underlying, depth: depth + 1)
    }
}
