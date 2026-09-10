import Foundation

actor AgentStructuredRecoveryExecution {
    var record: AgentStructuredRecoveryRecord
    let store: AgentStructuredRecoveryStore
    let authorizeAttempt: @Sendable (AgentRecoveryAttempt) async throws -> Bool
    let validateSession: @Sendable () async throws -> Void

    init(record: AgentStructuredRecoveryRecord, store: AgentStructuredRecoveryStore,
        authorizeAttempt: @escaping @Sendable (AgentRecoveryAttempt) async throws -> Bool,
        validateSession: @escaping @Sendable () async throws -> Void) {
        self.record = record
        self.store = store
        self.authorizeAttempt = authorizeAttempt
        self.validateSession = validateSession
    }

    func run<Output: AgentStructuredOutput>(response: Output.Type, decoder: JSONDecoder,
        backend: CodexResponsesBackend, session: ChatGPTSession,
        cancellation: AgentTurnCancellationHandle) async throws -> Output {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard try encoder.encode(record.format) == encoder.encode(Output.responseFormat) else {
            throw AgentRecoveryError.formatMismatch
        }
        if record.state == .cancelled { throw AgentRecoveryError.cancelled }
        if record.state == .failed { throw AgentRecoveryError.permanentlyFailed }
        if let data = record.completedPayload {
            try await validateSession()
            let value = try await decode(data, response: response, decoder: decoder)
            try Task.checkCancellation()
            try await validateSession()
            return value
        }
        let context = AgentStructuredRecoveryContext(authorizeAttempt: { try await self.reserveAttempt() },
            observe: { try await self.observe($0) }, failed: { try await self.recordFailure($0) })
        while true {
            do {
                try Task.checkCancellation()
                try await validateSession()
                let data = try await AgentStructuredRecoveryContext.$current.withValue(context) {
                    try await self.generate(backend: backend, session: session, cancellation: cancellation)
                }
                let value = try await decode(data, response: response, decoder: decoder)
                try Task.checkCancellation()
                try await validateSession()
                var completed = record
                completed.completedPayload = data
                completed.state = .completed
                try store.save(completed)
                record = completed
                return value
            } catch {
                if error is CancellationError || Task.isCancelled ||
                    (error as? AgentRuntimeError)?.interruption?.outcome == .cancelled {
                    record.state = .cancelled
                    record.completedPayload = nil
                    try store.save(record)
                    throw CancellationError()
                }
                if let failure = error as? AgentRuntimeError { record.lastFailure = failure }
                let replaceable = canReplace(error)
                record.state = replaceable || error is AgentRecoveryError || error is ChatGPTSessionError ? .interrupted : .failed
                try store.save(record)
                guard replaceable, record.attemptsUsed < record.maximumAttempts else { throw error }
                // The host sees the failure and controls any waiting/backoff in the required authorization callback.
            }
        }
    }

    private func reserveAttempt() async throws -> String {
        try Task.checkCancellation()
        try await validateSession()
        if let expiry = record.expiresAt, expiry <= Date() { throw AgentRecoveryError.stateExpired }
        guard record.attemptsUsed < record.maximumAttempts else { throw AgentRecoveryError.attemptsExhausted }
        let reason: AgentRecoveryAttempt.Reason = record.attemptsUsed == 0 ? .initial
            : record.lastFailure?.http?.statusCode == 401 ? .authenticationReissue : .replacement
        let id = UUID().uuidString
        guard try await authorizeAttempt(.init(operationID: record.handle.id, id: id,
            number: record.attemptsUsed + 1, maximumAttempts: record.maximumAttempts,
            reason: reason, previousFailure: record.lastFailure,
            previousResponseID: record.responseID, previousSequenceNumber: record.lastSequenceNumber)) else {
            throw AgentRecoveryError.attemptNotAuthorized
        }
        try Task.checkCancellation()
        try await validateSession()
        if let expiry = record.expiresAt, expiry <= Date() { throw AgentRecoveryError.stateExpired }
        record.attemptsUsed += 1
        record.attemptID = id
        record.responseID = nil
        record.lastSequenceNumber = nil
        record.state = .running
        // Persist before transmission: a crash may consume an unused slot but cannot reset the budget.
        try store.save(record)
        return id
    }

    private func observe(_ observation: ResponsesAttemptObservation) throws {
        record.responseID = observation.responseID
        record.lastSequenceNumber = observation.lastSequenceNumber
        try store.save(record)
    }

    private func recordFailure(_ failure: AgentRuntimeError) throws {
        record.lastFailure = failure
        try store.save(record)
    }

    private func canReplace(_ error: Error) -> Bool {
        guard let failure = error as? AgentRuntimeError, let interruption = failure.interruption,
              !interruption.hasToolActivity, !interruption.providerCompleted else { return false }
        if interruption.outcome == .disconnected {
            return interruption.transportErrorCode.map(RequestRetryPolicy.default.retryableURLErrorCodes.contains) ?? true
        }
        return interruption.outcome == .requestRejected &&
            failure.http.map { RequestRetryPolicy.default.retryableHTTPStatusCodes.contains($0.statusCode) } == true
    }

    private func decode<Output: AgentStructuredOutput>(_ data: Data, response: Output.Type,
        decoder: JSONDecoder) async throws -> Output {
        let capture = AgentOneShotResponseCapture<Output>(format: record.format, decoder: decoder)
        try await capture.validate(.init(threadID: record.thread.id, role: .assistant,
            text: String(decoding: data, as: UTF8.self)))
        return try await capture.value()
    }

    private func generate(backend: CodexResponsesBackend, session: ChatGPTSession,
        cancellation: AgentTurnCancellationHandle) async throws -> Data {
        let stream = try await backend.beginTurn(thread: record.thread, history: [],
            message: record.request, instructions: record.instructions, responseFormat: record.format,
            streamedStructuredOutput: nil, tools: [], session: session)
        cancellation.install { stream.interrupt() }
        defer { stream.interrupt() }
        var message: AgentMessage?
        var turnID: String?
        for try await event in stream.events {
            try Task.checkCancellation()
            try await validateSession()
            switch event {
            case let .turnStarted(turn):
                guard turn.threadID == record.thread.id, turnID == nil else { throw AgentRuntimeError.invalidTurnStart() }
                turnID = turn.id
            case let .assistantMessageCompleted(value):
                guard turnID != nil, value.threadID == record.thread.id else {
                    throw AgentRuntimeError.invalidBackendTurnEvent()
                }
                message = value
            case .toolCallRequested, .toolCallsRequested: throw AgentRecoveryError.toolsUnsupported
            case let .turnCompleted(summary):
                guard summary.turnID == turnID, summary.threadID == record.thread.id else {
                    throw AgentRuntimeError.invalidTurnCompletion()
                }
                guard let message else { throw AgentRuntimeError.assistantResponseMissing() }
                return Data(message.text.utf8)
            default: break
            }
        }
        throw AgentRuntimeError.turnSummaryMissing()
    }
}
