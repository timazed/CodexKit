import Foundation

actor AgentStructuredRecoveryExecution {
    var record: AgentStructuredRecoveryRecord
    let store: AgentStructuredRecoveryStore
    let authorizeAttempt: @Sendable (AgentRecoveryAttempt) async throws -> Bool
    let validateSession: @Sendable () async throws -> Void
    let lifecycle: AgentRecoveryLifecycle
    let logger: AgentLogger

    init(record: AgentStructuredRecoveryRecord, store: AgentStructuredRecoveryStore,
         lifecycle: AgentRecoveryLifecycle, logger: AgentLogger,
         authorizeAttempt: @escaping @Sendable (AgentRecoveryAttempt) async throws -> Bool,
         validateSession: @escaping @Sendable () async throws -> Void) {
        self.record = record; self.store = store; self.lifecycle = lifecycle; self.logger = logger
        self.authorizeAttempt = authorizeAttempt; self.validateSession = validateSession
    }

    func run<Output: AgentStructuredOutput>(response: Output.Type, decoder: JSONDecoder,
        backend: CodexResponsesBackend?, session: ChatGPTSession) async throws -> Output {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard try encoder.encode(record.format) == encoder.encode(Output.responseFormat) else {
            throw AgentRecoveryError.formatMismatch
        }
        if record.state == .cancelled { throw AgentRecoveryError.cancelled }
        if record.state == .failed { throw AgentRecoveryError.permanentlyFailed }
        let policy = record.retryPolicy ?? .init(backoff: .init(initialBackoff: 0, maxBackoff: 0))
        let context = AgentStructuredRecoveryContext(authorizeAttempt: { try await self.reserveAttempt() },
            observe: { try await self.observe($0) }, failed: { try await self.recordFailure($0) },
            beforeTransmission: { try await self.beforeTransmission() }, frozenBody: record.preparedRequest?.body)
        while true {
            do {
                try lifecycle.check()
                try await validateSession()
                if let data = record.completedPayload {
                    let value = try await decode(data, response: response, decoder: decoder)
                    try await validateSession()
                    try lifecycle.check()
                    emit("receipt.retrieved")
                    return value
                }
                if record.state == .failed { throw AgentRecoveryError.permanentlyFailed }
                guard let backend else { throw AgentRecoveryError.unsupportedBackend }
                let data = try await AgentStructuredRecoveryContext.$current.withValue(context) {
                    try await self.generate(backend: backend, session: session)
                }
                let value = try await decode(data, response: response, decoder: decoder)
                try await validateSession()
                var completed = record
                completed.completedPayload = data
                completed.state = .completed
                completed.completedAt = Date()
                completed.nextAttemptAt = nil
                completed.blocker = nil
                if let last = completed.attempts?.indices.last { completed.attempts?[last].state = .completed }
                try lifecycle.performWhileActive { try store.save(completed) }
                record = completed
                emit("receipt.saved")
                try await validateSession()
                try lifecycle.check()
                return value
            } catch {
                if error is CancellationError || Task.isCancelled ||
                    (error as? AgentRuntimeError)?.interruption?.outcome == .cancelled {
                    lifecycle.suspend()
                    let cancelled = (try? store.lifecycle(record.handle)?.state) == .cancelled
                    if cancelled {
                        record.state = .cancelled
                        record.completedPayload = nil
                    } else if record.completedPayload == nil { record.state = .suspended }
                    try store.save(record)
                    emit(cancelled ? "operation.cancelled" : "operation.suspended")
                    throw CancellationError()
                }
                // A failed persistence operation must never overwrite a possibly saved receipt or start another POST.
                let nsError = error as NSError
                if nsError.domain == NSCocoaErrorDomain || nsError.domain == NSPOSIXErrorDomain ||
                    (error as? AgentRecoveryError) == .storageLimitExceeded { throw error }
                if record.completedPayload != nil { throw error }
                if let failure = error as? AgentRuntimeError { record.lastFailure = failure }
                let auth = error is ChatGPTSessionError || (error as? AgentRuntimeError)?.http?.statusCode == 401
                let replaceable = policy.canReplace(error)
                if auth { record.blocker = .authenticationRequired }
                record.state = replaceable || error is AgentRecoveryError || auth ? .interrupted : .failed
                if replaceable, record.attemptsUsed < record.maximumAttempts {
                    let delay = max(policy.backoff.delayBeforeRetry(attempt: record.attemptsUsed),
                                    record.lastFailure?.http?.retryAfter ?? 0)
                    record.nextAttemptAt = Date().addingTimeInterval(delay)
                }
                try store.save(record)
                emit(auth ? "operation.authentication_required" : "attempt.failed")
                guard replaceable, record.attemptsUsed < record.maximumAttempts else { throw error }
            }
        }
    }

    private func reserveAttempt() async throws -> String {
        try lifecycle.check()
        try await validateSession()
        if let expiry = record.expiresAt, expiry <= Date() { throw AgentRecoveryError.stateExpired }
        guard record.attemptsUsed < record.maximumAttempts else { throw AgentRecoveryError.attemptsExhausted }
        if let next = record.nextAttemptAt, next > Date() {
            emit("operation.waiting")
            try await Task.sleep(for: .seconds(next.timeIntervalSinceNow))
        }
        try lifecycle.check()
        let reason: AgentRecoveryAttempt.Reason = record.attemptsUsed == 0 ? .initial
            : record.lastFailure?.http?.statusCode == 401 ? .authenticationReissue : .replacement
        let id = record.pendingAttemptID ?? UUID().uuidString
        record.pendingAttemptID = id
        try lifecycle.performWhileActive { try store.save(record) }
        guard try await authorizeAttempt(.init(operationID: record.handle.id, id: id,
            number: record.attemptsUsed + 1, maximumAttempts: record.maximumAttempts,
            reason: reason, previousFailure: record.lastFailure,
            previousResponseID: record.responseID, previousSequenceNumber: record.lastSequenceNumber)) else {
            throw AgentRecoveryError.attemptNotAuthorized
        }
        try lifecycle.check()
        try await validateSession()
        if let expiry = record.expiresAt, expiry <= Date() { throw AgentRecoveryError.stateExpired }
        record.attemptsUsed += 1
        record.attemptID = id
        record.pendingAttemptID = nil
        record.responseID = nil
        record.lastSequenceNumber = nil
        record.nextAttemptAt = nil
        record.state = .running
        record.blocker = nil
        var attempts = record.attempts ?? []
        attempts.append(.init(id: id, number: record.attemptsUsed, reservedAt: Date(), state: .reserved))
        record.attempts = attempts
        try lifecycle.performWhileActive { try store.save(record) }
        emit("attempt.reserved")
        return id
    }

    private func beforeTransmission() async throws {
        try await validateSession()
        try lifecycle.performWhileActive {
            if let index = record.attempts?.indices.last { record.attempts?[index].state = .transmissionAuthorized }
            try store.save(record)
        }
        emit("attempt.transmission_authorized")
    }

    private func observe(_ observation: ResponsesAttemptObservation) throws {
        try lifecycle.check()
        record.responseID = observation.responseID
        record.lastSequenceNumber = observation.lastSequenceNumber
        if let index = record.attempts?.indices.last {
            record.attempts?[index].responseID = observation.responseID
            record.attempts?[index].lastSequenceNumber = observation.lastSequenceNumber
        }
        try store.save(record)
    }
    private func recordFailure(_ failure: AgentRuntimeError) throws {
        record.lastFailure = failure
        if let index = record.attempts?.indices.last {
            record.attempts?[index].state = .failed
            record.attempts?[index].failure = failure
        }
        try store.save(record)
    }
    private func decode<Output: AgentStructuredOutput>(_ data: Data, response: Output.Type,
        decoder: JSONDecoder) async throws -> Output {
        let capture = AgentOneShotResponseCapture<Output>(format: record.format, decoder: decoder)
        try await capture.validate(.init(threadID: record.thread.id, role: .assistant,
            text: String(decoding: data, as: UTF8.self)))
        return try await capture.value()
    }
    private func generate(backend: CodexResponsesBackend, session: ChatGPTSession) async throws -> Data {
        var request = record.request
        request.resolvedModelSelection = .init(configuration: record.thread.configuration
            ?? backend.configuration.defaultThreadConfiguration, policyID: "recovered")
        let stream = try await backend.beginTurn(thread: record.thread, history: [],
            message: request, instructions: record.instructions, responseFormat: record.format,
            streamedStructuredOutput: nil, tools: [], session: session)
        defer { stream.interrupt() }
        var message: AgentMessage?
        var turnID: String?
        for try await event in stream.events {
            try lifecycle.check()
            try await validateSession()
            switch event {
            case let .turnStarted(turn):
                guard turn.threadID == record.thread.id, turnID == nil else { throw AgentRuntimeError.invalidTurnStart() }
                turnID = turn.id
            case let .assistantMessageCompleted(value):
                guard turnID != nil, value.threadID == record.thread.id else { throw AgentRuntimeError.invalidBackendTurnEvent() }
                message = value
            case .toolCallRequested, .toolCallsRequested: throw AgentRecoveryError.toolsUnsupported
            case let .turnCompleted(summary):
                guard summary.turnID == turnID, summary.threadID == record.thread.id else { throw AgentRuntimeError.invalidTurnCompletion() }
                guard let message else { throw AgentRuntimeError.assistantResponseMissing() }
                return Data(message.text.utf8)
            default: break
            }
        }
        throw AgentRuntimeError.turnSummaryMissing()
    }

    private func emit(_ name: String) { logger.recovery(name, record: record) }
}
