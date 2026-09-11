import Foundation

extension AgentLogger {
    func recovery(_ event: String, record: AgentStructuredRecoveryRecord) {
        var metadata = [
            "event": "recovery." + event, "event_version": "1",
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
