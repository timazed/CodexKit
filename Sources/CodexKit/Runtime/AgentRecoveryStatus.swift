import Foundation

public struct AgentStructuredRecoveryStatus: Codable, Sendable {
    public enum State: String, Codable, Sendable {
        case prepared, running, interrupted, completed, failed, cancelled, suspended, acknowledged, abandoned
    }
    public enum Blocker: String, Codable, Sendable {
        case authenticationRequired, accountMismatch, configurationUnavailable, incompatibleRecord, storageUnavailable
    }
    public enum Availability: String, Codable, Sendable {
        case ready, running, waiting, replacementEligible, completionSaved, suspended, exhausted
        case authenticationRequired, permanentlyCancelled, failed, acknowledged, abandoned, blocked, expired
    }
    public enum Action: String, Codable, Sendable {
        case execute, resume, readReceipt, manualRetry, signIn, acknowledge, abandon, wait
    }
    public let state: State
    public let attemptsUsed: Int
    public let maximumAttempts: Int
    public let responseID: String?
    public let lastSequenceNumber: Int?
    public let lastFailure: AgentRuntimeError?
    public let operationID: UUID?
    public let attemptID: String?
    public let hasSavedCompletion: Bool
    public let nextAttemptAt: Date?
    public let expiresAt: Date?
    public let blocker: Blocker?
    public let previousOperationID: UUID?
    public let successorID: UUID?
    public let rootOperationID: UUID?
    public let attempts: [AgentRecoveryAttemptSummary]
    public let hostJobID: String?
    public let inputRevision: String?
    public let scope: String?

    private enum CodingKeys: String, CodingKey {
        case state, attemptsUsed, maximumAttempts, responseID, lastSequenceNumber, lastFailure
        case operationID, attemptID, hasSavedCompletion, nextAttemptAt, expiresAt, blocker
        case previousOperationID, successorID, rootOperationID, attempts, hostJobID, inputRevision, scope
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let state = try c.decode(State.self, forKey: .state)
        self.init(state: state, attemptsUsed: try c.decode(Int.self, forKey: .attemptsUsed),
            maximumAttempts: try c.decode(Int.self, forKey: .maximumAttempts),
            responseID: try c.decodeIfPresent(String.self, forKey: .responseID),
            lastSequenceNumber: try c.decodeIfPresent(Int.self, forKey: .lastSequenceNumber),
            lastFailure: try c.decodeIfPresent(AgentRuntimeError.self, forKey: .lastFailure),
            operationID: try c.decodeIfPresent(UUID.self, forKey: .operationID),
            attemptID: try c.decodeIfPresent(String.self, forKey: .attemptID),
            hasSavedCompletion: try c.decodeIfPresent(Bool.self, forKey: .hasSavedCompletion) ?? (state == .completed),
            nextAttemptAt: try c.decodeIfPresent(Date.self, forKey: .nextAttemptAt),
            expiresAt: try c.decodeIfPresent(Date.self, forKey: .expiresAt),
            blocker: try c.decodeIfPresent(Blocker.self, forKey: .blocker),
            previousOperationID: try c.decodeIfPresent(UUID.self, forKey: .previousOperationID),
            successorID: try c.decodeIfPresent(UUID.self, forKey: .successorID),
            rootOperationID: try c.decodeIfPresent(UUID.self, forKey: .rootOperationID),
            attempts: try c.decodeIfPresent([AgentRecoveryAttemptSummary].self, forKey: .attempts) ?? [],
            hostJobID: try c.decodeIfPresent(String.self, forKey: .hostJobID),
            inputRevision: try c.decodeIfPresent(String.self, forKey: .inputRevision),
            scope: try c.decodeIfPresent(String.self, forKey: .scope))
    }

    public var attemptsRemaining: Int { max(0, maximumAttempts - attemptsUsed) }
    public var availability: Availability {
        if blocker == .authenticationRequired || blocker == .accountMismatch { return .authenticationRequired }
        if state == .cancelled { return .permanentlyCancelled }
        if state == .acknowledged { return .acknowledged }
        if state == .abandoned { return .abandoned }
        if state == .suspended { return .suspended }
        if hasSavedCompletion { return .completionSaved }
        if let expiresAt, expiresAt <= Date() { return .expired }
        if blocker != nil { return .blocked }
        if attemptsRemaining == 0 { return .exhausted }
        if state == .failed { return .failed }
        if let nextAttemptAt, nextAttemptAt > Date() { return .waiting }
        if state == .running { return .running }
        return attemptsUsed == 0 ? .ready : .replacementEligible
    }
    public var availableActions: [Action] {
        switch availability {
        case .authenticationRequired: return [.signIn]
        case .permanentlyCancelled, .acknowledged, .abandoned: return []
        case .completionSaved: return [.readReceipt, .acknowledge, .abandon]
        case .suspended: return hasSavedCompletion ? [.readReceipt, .resume, .abandon] : [.resume, .abandon]
        case .exhausted, .failed, .expired: return successorID == nil ? [.manualRetry, .abandon] : [.abandon]
        case .ready, .replacementEligible: return [.execute, .abandon]
        case .waiting: return [.wait, .resume, .abandon]
        case .running: return [.wait]
        case .blocked: return hasSavedCompletion ? [.readReceipt, .abandon] : [.abandon]
        }
    }

    init(state: State, attemptsUsed: Int = 0, maximumAttempts: Int = 0,
         responseID: String? = nil, lastSequenceNumber: Int? = nil, lastFailure: AgentRuntimeError? = nil,
         operationID: UUID? = nil, attemptID: String? = nil, hasSavedCompletion: Bool = false,
         nextAttemptAt: Date? = nil, expiresAt: Date? = nil, blocker: Blocker? = nil,
         previousOperationID: UUID? = nil, successorID: UUID? = nil, rootOperationID: UUID? = nil,
         attempts: [AgentRecoveryAttemptSummary] = [], hostJobID: String? = nil,
         inputRevision: String? = nil, scope: String? = nil) {
        self.state = state; self.attemptsUsed = attemptsUsed; self.maximumAttempts = maximumAttempts
        self.responseID = responseID; self.lastSequenceNumber = lastSequenceNumber; self.lastFailure = lastFailure
        self.operationID = operationID; self.attemptID = attemptID; self.hasSavedCompletion = hasSavedCompletion
        self.nextAttemptAt = nextAttemptAt; self.expiresAt = expiresAt; self.blocker = blocker
        self.previousOperationID = previousOperationID; self.successorID = successorID; self.rootOperationID = rootOperationID
        self.attempts = attempts; self.hostJobID = hostJobID; self.inputRevision = inputRevision; self.scope = scope
    }
}

public enum AgentRecoveryRetrySelection: String, Codable, Sendable { case preserve, reselect }

/// Policy belongs to an operation and is persisted. It does not inherit a transport retry loop.
public struct AgentRecoveryRetryPolicy: Codable, Equatable, Sendable {
    public var backoff: RequestRetryPolicy
    public var retryableProviderCodes: Set<String>
    public var retriesInvalidStructuredOutput: Bool
    public init(backoff: RequestRetryPolicy = .default, retryableProviderCodes: Set<String> = [],
                retriesInvalidStructuredOutput: Bool = false) {
        self.backoff = backoff
        self.retryableProviderCodes = retryableProviderCodes
        self.retriesInvalidStructuredOutput = retriesInvalidStructuredOutput
    }
    public static let `default` = Self()
    func canReplace(_ error: Error) -> Bool {
        if retriesInvalidStructuredOutput, error is DecodingError { return true }
        guard let failure = error as? AgentRuntimeError else { return false }
        if failure.http?.isQuotaExceeded == true || failure.knownCode == .quotaExceeded { return false }
        if failure.interruption?.hasToolActivity == true || failure.executionLimit != nil { return false }
        if retriesInvalidStructuredOutput, failure.code.hasPrefix("structured_output_") { return true }
        guard let interruption = failure.interruption, !interruption.providerCompleted else { return false }
        switch interruption.outcome {
        case .disconnected:
            return interruption.transportErrorCode.map(backoff.retryableURLErrorCodes.contains) ?? true
        case .requestRejected:
            guard let http = failure.http, http.statusCode != 401, http.statusCode != 403 else { return false }
            return backoff.retryableHTTPStatusCodes.contains(http.statusCode)
        case .providerFailed:
            return failure.http?.providerCode.map(retryableProviderCodes.contains) ?? false
        default: return false
        }
    }
}

/// A saved payload is validated under its ORIGINAL contract, independently of a newer app type.
public struct AgentStructuredRecoveryReceipt: Sendable {
    public let handle: AgentStructuredRecoveryHandle
    public let accountBinding: ChatGPTSessionBinding
    public let format: AgentStructuredOutputFormat
    public let contractVersion: String?
    public let payload: Data
    public let hostJobID: String?
    public let inputRevision: String?
    public let previousOperationID: UUID?
    public let completedAt: Date?

    public func decode<Output: Decodable>(_ type: Output.Type, decoder: JSONDecoder = JSONDecoder()) throws -> Output {
        try decoder.decode(type, from: payload)
    }
    init(record: AgentStructuredRecoveryRecord) throws {
        guard let payload = record.completedPayload else { throw AgentRecoveryError.completionUnavailable }
        try AgentJSONSchemaValidator.validateSchema(record.format.schema)
        try AgentJSONSchemaValidator.validate(JSONDecoder().decode(JSONValue.self, from: payload), schema: record.format.schema)
        self.handle = record.handle; accountBinding = record.binding; format = record.format
        contractVersion = record.contractVersion; self.payload = payload; hostJobID = record.hostJobID
        inputRevision = record.inputRevision; previousOperationID = record.previousOperationID; completedAt = record.completedAt
    }
}
