import Foundation

/// Persist this handle beside the host's logical operation. It contains no credentials or model output.
public struct AgentStructuredRecoveryHandle: Codable, Hashable, Sendable {
    public let id: UUID
    init(id: UUID = UUID()) { self.id = id }
}

public enum AgentRecoveryError: String, Error, Codable, Sendable, LocalizedError {
    case unsupportedBackend, ephemeralRequired, toolsUnsupported, stateUnavailable, stateExpired
    case stateInvalid, busy, formatMismatch, attemptsExhausted, attemptNotAuthorized, permanentlyFailed
    case cancelled, completionUnavailable

    public var errorDescription: String? {
        switch self {
        case .unsupportedBackend: "Structured recovery requires the Codex Responses backend."
        case .ephemeralRequired: "Structured recovery requires an ephemeral request."
        case .toolsUnsupported: "Recoverable structured requests cannot use tools."
        case .stateUnavailable: "The local recovery state is unavailable. No replacement request was started."
        case .stateExpired: "The local recovery state has expired. No replacement request was started."
        case .stateInvalid: "The local recovery state is invalid."
        case .busy: "This recovery operation is already in use."
        case .formatMismatch: "The structured response contract differs from the saved request."
        case .attemptsExhausted: "The saved request has exhausted its generation attempt budget."
        case .attemptNotAuthorized: "The host did not authorize another generation attempt."
        case .permanentlyFailed: "This operation failed permanently. Inspect its saved failure before starting a new operation."
        case .cancelled: "This operation was explicitly cancelled."
        case .completionUnavailable: "No complete validated result was saved for this operation."
        }
    }
}

public struct AgentRecoveryAttempt: Sendable {
    public enum Reason: String, Codable, Sendable { case initial, replacement, authenticationReissue }
    public let operationID: UUID
    /// Unique HTTP generation attempt ID; use this to atomically reserve the host's budget.
    public let id: String
    public let number: Int
    public let maximumAttempts: Int
    public let reason: Reason
    public let previousFailure: AgentRuntimeError?
    public let previousResponseID: String?
    public let previousSequenceNumber: Int?
}

public struct AgentStructuredRecoveryStatus: Codable, Sendable {
    public enum State: String, Codable, Sendable {
        case prepared, running, interrupted, completed, failed, cancelled
    }
    public let state: State
    public let attemptsUsed: Int
    public let maximumAttempts: Int
    public let responseID: String?
    public let lastSequenceNumber: Int?
    public let lastFailure: AgentRuntimeError?
}

struct AgentStructuredRecoveryRecord: Codable, Sendable {
    var version = 1
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
    /// Exact UTF-8 JSON preserves integers and custom decoder behavior; never store partial output here.
    var completedPayload: Data?

    var status: AgentStructuredRecoveryStatus {
        .init(state: state, attemptsUsed: attemptsUsed, maximumAttempts: maximumAttempts,
              responseID: responseID, lastSequenceNumber: lastSequenceNumber, lastFailure: lastFailure)
    }
}

struct AgentStructuredRecoveryContext: Sendable {
    @TaskLocal static var current: AgentStructuredRecoveryContext?
    let authorizeAttempt: @Sendable () async throws -> String
    let observe: @Sendable (ResponsesAttemptObservation) async throws -> Void
    let failed: @Sendable (AgentRuntimeError) async throws -> Void
}
