import Foundation

extension AgentRuntime {
    /// Resolves configuration and saves a tool-free request. Makes no generation POST.
    /// Persist the handle with the host job BEFORE sendRecovering. Expiry only gates new attempts.
    public func prepareStructuredRecovery<Output: AgentStructuredOutput>(
        _ request: Request, in threadID: String, response: Output.Type,
        store: AgentStructuredRecoveryStore, maximumAttempts: Int = 3, expiresAt: Date? = nil,
        retryPolicy: AgentRecoveryRetryPolicy = .default, scope: String? = nil,
        hostJobID: String? = nil, inputRevision: String? = nil, contractVersion: String? = nil,
        previousOperationID: UUID? = nil
    ) async throws -> AgentStructuredRecoveryHandle {
        try Task.checkCancellation()
        guard request.isEphemeral else { throw AgentRecoveryError.ephemeralRequired }
        guard request.hasContent else { throw AgentRuntimeError.invalidMessageContent() }
        guard [scope, hostJobID, inputRevision, contractVersion, request.selectionPurpose].compactMap({ $0 })
            .allSatisfy({ $0.utf8.count <= 1_024 }) else { throw AgentRecoveryError.stateInvalid }
        try validateClientRequestID(request.clientRequestID)
        guard (1...1_000).contains(maximumAttempts) else { throw AgentRecoveryError.attemptsExhausted }
        guard let supporting = backend as? any AgentBackendStructuredRecoverySupporting else { throw AgentRecoveryError.unsupportedBackend }
        guard let originalThread = thread(for: threadID) else { throw AgentRuntimeError.threadNotFound(threadID) }
        let session = try await sessionManager.requireSession()
        try validateThreadAuthentication(originalThread, session: session)
        let (request, selectedThread) = try await resolveRequestConfiguration(request, thread: originalThread,
            responseFormat: Output.responseFormat, session: session)
        let skills = try resolveTurnSkills(thread: selectedThread, message: request)
        guard skills.compiledToolPolicy.requiredToolNames.isEmpty,
              skills.compiledToolPolicy.toolSequence?.isEmpty != false else { throw AgentRecoveryError.toolsUnsupported }
        let instructions = try await resolveInstructions(thread: selectedThread, message: request, resolvedTurnSkills: skills)
        try AgentJSONSchemaValidator.validateSchema(Output.responseFormat.schema)
        let adapter = try await supporting.structuredRecoveryAdapter
        let frozenThread = AgentThread(id: selectedThread.id,
            configuration: selectedThread.configuration ?? adapter.backend.configuration.defaultThreadConfiguration)
        let handle = AgentStructuredRecoveryHandle()
        let correlated = request.correlated(with: request.clientRequestID ?? handle.id.uuidString)
        let prepared = try await adapter.prepare(thread: frozenThread, request: correlated,
            instructions: instructions.text, format: Output.responseFormat, session: session)
        let lease = try store.acquire(handle)
        defer { withExtendedLifetime(lease) {} }
        try await validateActiveAuthentication(session)
        var record = AgentStructuredRecoveryRecord(handle: handle, binding: session.binding, thread: frozenThread,
            request: correlated, instructions: instructions.text, format: Output.responseFormat,
            endpoint: prepared.endpoint, enableReasoningSummaries: prepared.enableReasoningSummaries,
            maximumAttempts: maximumAttempts, expiresAt: expiresAt)
        record.preparedRequest = prepared; record.retryPolicy = retryPolicy; record.createdAt = Date()
        record.scope = scope; record.hostJobID = hostJobID; record.inputRevision = inputRevision
        record.contractVersion = contractVersion; record.previousOperationID = previousOperationID
        record.rootOperationID = previousOperationID ?? handle.id; record.baselineConfiguration = originalThread.configuration
        try store.save(record)
        logger.recovery("operation.prepared", record: record)
        return handle
    }

    /// Reopens an existing operation. Task/background cancellation suspends; explicit cancellation is terminal.
    /// A saved completion makes zero generation POSTs and invokes neither selector nor attempt authorization.
    public func sendRecovering<Output: AgentStructuredOutput>(
        _ handle: AgentStructuredRecoveryHandle, response: Output.Type,
        store: AgentStructuredRecoveryStore, decoder: JSONDecoder = JSONDecoder(),
        expectedContractVersion: String? = nil,
        authorizeAttempt: @escaping @Sendable (AgentRecoveryAttempt) async throws -> Bool
    ) async throws -> Output {
        try Task.checkCancellation()
        let lease = try store.acquire(handle)
        defer { withExtendedLifetime(lease) {} }
        var record = try store.load(handle)
        let session = try await recoverySession(for: record)
        if let expectedContractVersion, expectedContractVersion != record.contractVersion {
            throw AgentRecoveryError.formatMismatch
        }
        guard record.state != .cancelled, try store.lifecycle(handle)?.state != .cancelled else { throw AgentRecoveryError.cancelled }
        var responsesBackend: CodexResponsesBackend?
        if record.completedPayload == nil {
            guard let supporting = backend as? any AgentBackendStructuredRecoverySupporting else { throw AgentRecoveryError.unsupportedBackend }
            let adapter = try await supporting.structuredRecoveryAdapter
            guard adapter.backend.configuration.baseURL == record.endpoint else {
                record.blocker = .configurationUnavailable
                try store.save(record)
                throw ChatGPTSessionError.configurationChanged
            }
            if record.preparedRequest == nil {
                guard adapter.backend.configuration.enableReasoningSummaries == record.enableReasoningSummaries else {
                    throw ChatGPTSessionError.configurationChanged
                }
                record.preparedRequest = try await adapter.prepare(thread: record.thread, request: record.request,
                    instructions: record.instructions, format: record.format, session: session)
                record.version = 2
            }
            responsesBackend = adapter.backend
        }
        let lifecycle = try store.beginLifecycle(handle)
        if record.state == .suspended { record.state = .interrupted }
        record.blocker = nil
        try store.save(record)
        let execution = AgentStructuredRecoveryExecution(record: record, store: store, lifecycle: lifecycle,
            logger: logger, authorizeAttempt: authorizeAttempt, validateSession: { [sessionManager] in
                let current = try await sessionManager.requireSession()
                try Self.validateLease(current, against: session)
            })
        let control = AgentExecutionControl(threadID: record.thread.id, execution: nil)
        authenticatedExecutionControls[control.id] = control
        let context = authenticationContext(for: session)
        let activity = await backgroundActivityProvider.beginActivity(named: "CodexKit structured recovery") {
            lifecycle.suspend()
            control.cancellation.cancel()
        }
        let selectedBackend = responsesBackend
        let operation = Task {
            try await withTaskCancellationHandler {
                try await AgentAuthenticationContext.$current.withValue(context) {
                    try await execution.run(response: response, decoder: decoder, backend: selectedBackend, session: session)
                }
            } onCancel: { lifecycle.suspend() }
        }
        control.cancellation.install { operation.cancel() }
        // Stop commands work across runtimes and processes, including while the host authorizes or waits.
        let monitor = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(50)); try lifecycle.check() }
                catch { if !Task.isCancelled { operation.cancel() }; return }
            }
        }
        defer {
            monitor.cancel(); activity.end(); control.cancellation.clear(); control.finish()
            authenticatedExecutionControls.removeValue(forKey: control.id)
        }
        return try await withTaskCancellationHandler {
            let value = try await operation.value
            try lifecycle.check()
            return value
        } onCancel: {
            lifecycle.suspend()
            operation.cancel()
        }
    }

    func recoverySession(for record: AgentStructuredRecoveryRecord) async throws -> ChatGPTSession {
        let session = try await sessionManager.requireSession()
        guard session.binding == record.binding else { throw ChatGPTSessionError.accountChanged }
        return session
    }
}
