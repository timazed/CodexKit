import Foundation

enum AgentRecoveryEvent: Sendable {
    case operation(Operation)
    case attempt(Attempt)
    case receipt(Receipt)

    enum Operation: Sendable {
        case prepared, waiting, authenticationRequired, cancelled, suspended, abandoned, manualRetryCreated
    }

    enum Attempt: Sendable {
        case reserved, transmissionAuthorized, failed
    }

    enum Receipt: Sendable {
        case saved, retrieved, acknowledged
    }

    // Keep the external telemetry contract at the serialization boundary.
    fileprivate var serializedName: String {
        switch self {
        case .operation(.prepared): "recovery.operation.prepared"
        case .operation(.waiting): "recovery.operation.waiting"
        case .operation(.authenticationRequired): "recovery.operation.authentication_required"
        case .operation(.cancelled): "recovery.operation.cancelled"
        case .operation(.suspended): "recovery.operation.suspended"
        case .operation(.abandoned): "recovery.operation.abandoned"
        case .operation(.manualRetryCreated): "recovery.operation.manual_retry_created"
        case .attempt(.reserved): "recovery.attempt.reserved"
        case .attempt(.transmissionAuthorized): "recovery.attempt.transmission_authorized"
        case .attempt(.failed): "recovery.attempt.failed"
        case .receipt(.saved): "recovery.receipt.saved"
        case .receipt(.retrieved): "recovery.receipt.retrieved"
        case .receipt(.acknowledged): "recovery.receipt.acknowledged"
        }
    }
}

extension AgentLogger {
    func recovery(_ event: AgentRecoveryEvent, record: AgentStructuredRecoveryRecord) {
        var metadata = [
            "event": event.serializedName, "event_version": "1",
            "operation_id": record.handle.id.uuidString,
            "root_operation_id": (record.rootOperationID ?? record.handle.id).uuidString,
            "attempts_used": String(record.attemptsUsed), "maximum_attempts": String(record.maximumAttempts),
            "has_saved_completion": String(record.completedPayload != nil)
        ]
        metadata["attempt_id"] = record.attemptID
        metadata["previous_operation_id"] = record.previousOperationID?.uuidString
        metadata["successor_id"] = record.successorID?.uuidString
        metadata["provider_response_id"] = record.responseID
        metadata["model"] = record.thread.configuration?.model
        metadata["reasoning_effort"] = record.thread.configuration?.reasoningEffort.rawValue
        metadata["error_code"] = record.lastFailure?.code
        metadata["http_status"] = record.lastFailure?.http.map { String($0.statusCode) }
        metadata["provider_code"] = record.lastFailure?.http?.providerCode
        metadata["transport_domain"] = record.lastFailure?.interruption?.transportErrorDomain
        metadata["transport_code"] = record.lastFailure?.interruption?.transportErrorCode.map(String.init)
        // Never emit error.message, request content, account identity, scope, or host metadata.
        info(.recovery, "Structured recovery event.", metadata: metadata)
    }
}
