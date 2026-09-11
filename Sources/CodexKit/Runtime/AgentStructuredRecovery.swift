import Foundation

/// Persist beside the host's logical job. This identity is not the host's idempotent commit key.
public struct AgentStructuredRecoveryHandle: Codable, Hashable, Sendable {
    public let id: UUID
    init(id: UUID = UUID()) { self.id = id }
}

public enum AgentRecoveryError: String, Error, Codable, Sendable, LocalizedError {
    case unsupportedBackend, ephemeralRequired, toolsUnsupported, stateUnavailable, stateExpired
    case stateInvalid, busy, formatMismatch, attemptsExhausted, attemptNotAuthorized, permanentlyFailed
    case cancelled, completionUnavailable, suspended, unsupportedRecordVersion, storageLimitExceeded
    case retryAlreadyCreated, retryNotAllowed, retryConfigurationMismatch

    public var errorDescription: String? {
        switch self {
        case .unsupportedBackend: "This backend does not delegate structured request recovery."
        case .ephemeralRequired: "Structured recovery requires an ephemeral request."
        case .toolsUnsupported: "Recoverable structured requests cannot use tools."
        case .stateUnavailable: "The local recovery state is unavailable. No replacement was started."
        case .stateExpired: "Permission to start another generation has expired."
        case .stateInvalid: "The local recovery state is invalid."
        case .busy: "This operation already has an execution owner."
        case .formatMismatch: "Use the saved receipt's original contract to decode or migrate this result."
        case .attemptsExhausted: "The saved generation budget is exhausted. A deliberate manual retry is required."
        case .attemptNotAuthorized: "The host did not authorize this generation."
        case .permanentlyFailed: "This operation failed. Inspect its failure before deliberately retrying."
        case .cancelled: "This operation was permanently cancelled."
        case .completionUnavailable: "No complete validated result was saved."
        case .suspended: "This execution was suspended. Reopen the same handle to continue."
        case .unsupportedRecordVersion: "This SDK cannot read the recovery record version. The record was preserved."
        case .storageLimitExceeded: "The recovery store is full. Existing receipts were preserved."
        case .retryAlreadyCreated: "A successor already exists. Inspect successorID instead of creating another budget."
        case .retryNotAllowed: "Resume suspended work or retrieve its receipt instead of resetting its budget."
        case .retryConfigurationMismatch: "This retry action was already used with different settings."
        }
    }
}

public struct AgentRecoveryAttempt: Sendable {
    public enum Reason: String, Codable, Sendable { case initial, replacement, authenticationReissue }
    public let operationID: UUID
    /// Persistently reserve the host budget by this ID. Authorization can repeat after a crash.
    public let id: String
    public let number: Int
    public let maximumAttempts: Int
    public let reason: Reason
    public let previousFailure: AgentRuntimeError?
    public let previousResponseID: String?
    public let previousSequenceNumber: Int?
}

public struct AgentRecoveryAttemptSummary: Codable, Sendable {
    public enum State: String, Codable, Sendable { case reserved, transmissionAuthorized, failed, completed }
    public let id: String
    public let number: Int
    public let reservedAt: Date
    public var state: State
    public var responseID: String?
    public var lastSequenceNumber: Int?
    public var failure: AgentRuntimeError?
}

struct AgentStructuredRecoveryRecord: Codable, Sendable {
    var version = 2
    let handle: AgentStructuredRecoveryHandle
    let binding: ChatGPTSessionBinding
    let thread: AgentThread
    let request: Request
    let instructions: String
    let format: AgentStructuredOutputFormat
    let endpoint: URL
    let enableReasoningSummaries: Bool
    let maximumAttempts: Int
    let expiresAt: Date?
    var state: AgentStructuredRecoveryStatus.State = .prepared
    var attemptsUsed = 0
    var attemptID: String?
    var responseID: String?
    var lastSequenceNumber: Int?
    var lastFailure: AgentRuntimeError?
    /// Exact JSON bytes, written only after terminal completion and validation.
    var completedPayload: Data?
    // Optional additions keep alpha.30 records decodable without rewriting their history.
    var preparedRequest: AgentRecoveryPreparedRequest?
    var retryPolicy: AgentRecoveryRetryPolicy?
    var pendingAttemptID: String?
    var nextAttemptAt: Date?
    var createdAt: Date?
    var updatedAt: Date?
    var completedAt: Date?
    var scope: String?
    var hostJobID: String?
    var inputRevision: String?
    var contractVersion: String?
    var previousOperationID: UUID?
    var rootOperationID: UUID?
    var retryActionID: UUID?
    var successorID: UUID?
    var successorActionID: UUID?
    var successorMaximumAttempts: Int?
    var successorSelection: AgentRecoveryRetrySelection?
    var successorExpiresAt: Date?
    var successorPolicy: AgentRecoveryRetryPolicy?
    var baselineConfiguration: AgentThreadConfiguration?
    var attempts: [AgentRecoveryAttemptSummary]?
    var blocker: AgentStructuredRecoveryStatus.Blocker?

    var status: AgentStructuredRecoveryStatus { snapshot() }
    func snapshot(lifecycle: RecoveryLifecycleRecord? = nil) -> AgentStructuredRecoveryStatus {
        let state: AgentStructuredRecoveryStatus.State
        switch lifecycle?.state {
        case .cancelled: state = .cancelled
        case .suspended: state = .suspended
        default: state = self.state
        }
        return .init(state: state, attemptsUsed: attemptsUsed, maximumAttempts: maximumAttempts,
            responseID: responseID, lastSequenceNumber: lastSequenceNumber, lastFailure: lastFailure,
            operationID: handle.id, attemptID: attemptID, hasSavedCompletion: completedPayload != nil,
            nextAttemptAt: nextAttemptAt, expiresAt: expiresAt, blocker: blocker,
            previousOperationID: previousOperationID, successorID: successorID,
            rootOperationID: rootOperationID ?? handle.id, attempts: attempts ?? [],
            hostJobID: hostJobID, inputRevision: inputRevision, scope: scope)
    }
}

struct AgentStructuredRecoveryContext: Sendable {
    @TaskLocal static var current: AgentStructuredRecoveryContext?
    let authorizeAttempt: @Sendable () async throws -> String
    let observe: @Sendable (ResponsesAttemptObservation) async throws -> Void
    let failed: @Sendable (AgentRuntimeError) async throws -> Void
    var beforeTransmission: @Sendable () async throws -> Void = {}
    var frozenBody: Data? = nil
}
