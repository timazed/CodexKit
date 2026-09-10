import Foundation

extension AgentRuntime {
    /// Freezes an ephemeral, tool-free request locally without making a generation request.
    /// Persist the returned handle before calling `sendRecovering`. Expiry limits local recovery,
    /// not the duration of a running generation. No generation deadline is introduced by this API.
    public func prepareStructuredRecovery<Output: AgentStructuredOutput>(
        _ request: Request, in threadID: String, response: Output.Type,
        store: AgentStructuredRecoveryStore, maximumAttempts: Int = 3, expiresAt: Date? = nil
    ) async throws -> AgentStructuredRecoveryHandle {
        try Task.checkCancellation()
        guard request.isEphemeral else { throw AgentRecoveryError.ephemeralRequired }
        guard request.hasContent else { throw AgentRuntimeError.invalidMessageContent() }
        try validateClientRequestID(request.clientRequestID)
        guard maximumAttempts > 0 else { throw AgentRecoveryError.attemptsExhausted }
        guard let backend = backend as? CodexResponsesBackend else { throw AgentRecoveryError.unsupportedBackend }
        guard let thread = thread(for: threadID) else { throw AgentRuntimeError.threadNotFound(threadID) }
        let session = try await sessionManager.requireSession()
        try validateThreadAuthentication(thread, session: session)
        let skills = try resolveTurnSkills(thread: thread, message: request)
        guard skills.compiledToolPolicy.requiredToolNames.isEmpty,
              skills.compiledToolPolicy.toolSequence?.isEmpty != false else { throw AgentRecoveryError.toolsUnsupported }
        let instructions = try await resolveInstructions(thread: thread, message: request, resolvedTurnSkills: skills)
        try AgentJSONSchemaValidator.validateSchema(Output.responseFormat.schema)
        let configuration = backend.configuration
        let frozenThread = AgentThread(id: thread.id,
            configuration: instructions.threadConfiguration ?? thread.configuration ?? configuration.defaultThreadConfiguration)
        let handle = AgentStructuredRecoveryHandle()
        let lease = try store.acquire(handle)
        defer { withExtendedLifetime(lease) {} }
        try await validateActiveAuthentication(session)
        try store.save(.init(handle: handle, binding: session.binding, thread: frozenThread,
            request: request.correlated(with: request.clientRequestID ?? handle.id.uuidString),
            instructions: instructions.text, format: Output.responseFormat, endpoint: configuration.baseURL,
            enableReasoningSummaries: configuration.enableReasoningSummaries,
            maximumAttempts: maximumAttempts, expiresAt: expiresAt))
        return handle
    }

    /// Returns a saved completion, or explicitly authorized replacement generations. Never resumes a remote stream.
    /// The required callback runs before EVERY generation POST, including a 401 authentication reissue.
    /// Persistently reserve the host budget by attempt.id inside the callback; false sends nothing.
    /// SDK transient retries are disabled for this operation regardless of backend retry configuration.
    public func sendRecovering<Output: AgentStructuredOutput>(
        _ handle: AgentStructuredRecoveryHandle, response: Output.Type,
        store: AgentStructuredRecoveryStore, decoder: JSONDecoder = JSONDecoder(),
        authorizeAttempt: @escaping @Sendable (AgentRecoveryAttempt) async throws -> Bool
    ) async throws -> Output {
        try Task.checkCancellation()
        guard let backend = backend as? CodexResponsesBackend else { throw AgentRecoveryError.unsupportedBackend }
        let lease = try store.acquire(handle)
        defer { withExtendedLifetime(lease) {} }
        let record = try store.load(handle)
        let session = try await recoverySession(for: record)
        let configuration = backend.configuration
        guard configuration.baseURL == record.endpoint,
              configuration.enableReasoningSummaries == record.enableReasoningSummaries else {
            throw ChatGPTSessionError.configurationChanged
        }
        let execution = AgentStructuredRecoveryExecution(record: record, store: store,
            authorizeAttempt: authorizeAttempt, validateSession: { [sessionManager] in
                let current = try await sessionManager.requireSession()
                try Self.validateLease(current, against: session)
            })
        let control = AgentExecutionControl(threadID: record.thread.id, execution: nil)
        authenticatedExecutionControls[control.id] = control
        defer {
            authenticatedExecutionControls.removeValue(forKey: control.id)
            control.finish()
            control.cancellation.clear()
        }
        let activity = await backgroundActivityProvider.beginActivity(named: "CodexKit structured recovery") {
            control.cancellation.cancel()
        }
        defer { activity.end() }
        return try await withTaskCancellationHandler {
            try await AgentAuthenticationContext.$current.withValue(authenticationContext(for: session)) {
                try await execution.run(response: response, decoder: decoder, backend: backend,
                    session: session, cancellation: control.cancellation)
            }
        } onCancel: { control.cancellation.cancel() }
    }

    /// Read-only, local, account-bound status. A persisted running state after relaunch means the
    /// prior process stopped before recording an outcome, not that a provider response is resumable.
    public func structuredRecoveryStatus(_ handle: AgentStructuredRecoveryHandle,
        store: AgentStructuredRecoveryStore) async throws -> AgentStructuredRecoveryStatus {
        let lease = try store.acquire(handle)
        defer { withExtendedLifetime(lease) {} }
        let record = try store.load(handle)
        _ = try await recoverySession(for: record)
        return record.status
    }

    /// Permanently cancels an idle saved operation. Cancel the task running `sendRecovering` for active work.
    public func cancelStructuredRecovery(_ handle: AgentStructuredRecoveryHandle,
        store: AgentStructuredRecoveryStore) async throws {
        let lease = try store.acquire(handle)
        defer { withExtendedLifetime(lease) {} }
        var record = try store.load(handle)
        _ = try await recoverySession(for: record, checkExpiry: false)
        record.state = .cancelled
        record.completedPayload = nil
        try store.save(record)
    }

    /// Call only after the host atomically commits the result. A later reopen reports unavailable;
    /// it never silently starts a replacement request.
    public func acknowledgeStructuredRecovery(_ handle: AgentStructuredRecoveryHandle,
        store: AgentStructuredRecoveryStore) async throws {
        let lease = try store.acquire(handle)
        defer { withExtendedLifetime(lease) {} }
        let record = try store.load(handle)
        _ = try await recoverySession(for: record, checkExpiry: false)
        guard record.state == .completed else { throw AgentRecoveryError.completionUnavailable }
        try store.remove(handle)
    }

    private func recoverySession(for record: AgentStructuredRecoveryRecord,
        checkExpiry: Bool = true) async throws -> ChatGPTSession {
        let session = try await sessionManager.requireSession()
        guard session.binding == record.binding else { throw ChatGPTSessionError.accountChanged }
        if checkExpiry, let expiry = record.expiresAt, expiry <= Date() { throw AgentRecoveryError.stateExpired }
        return session
    }
}
