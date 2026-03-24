import Foundation

extension AgentRuntime {
    func resolveToolInvocation(
        _ invocation: ToolInvocation,
        session: ChatGPTSession,
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    ) async throws -> ToolResultEnvelope {
        try await resolveToolInvocationImpl(
            invocation,
            session: session,
            yieldThreadStatusChanged: { threadID, status in
                continuation.yield(.threadStatusChanged(threadID: threadID, status: status))
            },
            yieldApprovalRequested: { approval in
                continuation.yield(.approvalRequested(approval))
            },
            yieldApprovalResolved: { resolution in
                continuation.yield(.approvalResolved(resolution))
            }
        )
    }

    func resolveToolInvocation<Output: Sendable>(
        _ invocation: ToolInvocation,
        session: ChatGPTSession,
        continuation: AsyncThrowingStream<AgentStructuredStreamEvent<Output>, Error>.Continuation
    ) async throws -> ToolResultEnvelope {
        try await resolveToolInvocationImpl(
            invocation,
            session: session,
            yieldThreadStatusChanged: { threadID, status in
                continuation.yield(.threadStatusChanged(threadID: threadID, status: status))
            },
            yieldApprovalRequested: { approval in
                continuation.yield(.approvalRequested(approval))
            },
            yieldApprovalResolved: { resolution in
                continuation.yield(.approvalResolved(resolution))
            }
        )
    }

    private func resolveToolInvocationImpl(
        _ invocation: ToolInvocation,
        session: ChatGPTSession,
        yieldThreadStatusChanged: (String, AgentThreadStatus) -> Void,
        yieldApprovalRequested: (ApprovalRequest) -> Void,
        yieldApprovalResolved: (ApprovalResolution) -> Void
    ) async throws -> ToolResultEnvelope {
        if let definition = await toolRegistry.definition(named: invocation.toolName),
           definition.approvalPolicy == .requiresApproval {
            let approval = ApprovalRequest(
                threadID: invocation.threadID,
                turnID: invocation.turnID,
                toolInvocation: invocation,
                title: "Approve \(invocation.toolName)?",
                message: definition.approvalMessage
                    ?? "This tool requires explicit approval before it can run."
            )

            appendHistoryItem(
                .approval(
                    AgentApprovalRecord(
                        kind: .requested,
                        request: approval,
                        occurredAt: Date()
                    )
                ),
                threadID: invocation.threadID,
                createdAt: Date()
            )
            try setPendingState(
                .approval(
                    AgentPendingApprovalState(
                        request: approval,
                        requestedAt: Date()
                    )
                ),
                for: invocation.threadID
            )
            try await setThreadStatus(.waitingForApproval, for: invocation.threadID)
            yieldThreadStatusChanged(invocation.threadID, .waitingForApproval)
            yieldApprovalRequested(approval)

            let decision = try await approvalCoordinator.requestApproval(approval)
            let resolution = ApprovalResolution(
                requestID: approval.id,
                threadID: approval.threadID,
                turnID: approval.turnID,
                decision: decision
            )
            appendHistoryItem(
                .approval(
                    AgentApprovalRecord(
                        kind: .resolved,
                        request: approval,
                        resolution: resolution,
                        occurredAt: resolution.decidedAt
                    )
                ),
                threadID: invocation.threadID,
                createdAt: resolution.decidedAt
            )
            try setPendingState(nil, for: invocation.threadID)
            yieldApprovalResolved(resolution)

            guard decision == .approved else {
                let denied = ToolResultEnvelope.denied(invocation: invocation)
                try setLatestToolState(
                    latestToolState(for: invocation, result: denied, updatedAt: resolution.decidedAt),
                    for: invocation.threadID
                )
                appendHistoryItem(
                    .toolResult(
                        AgentToolResultRecord(
                            threadID: invocation.threadID,
                            turnID: invocation.turnID,
                            result: denied,
                            completedAt: resolution.decidedAt
                        )
                    ),
                    threadID: invocation.threadID,
                    createdAt: resolution.decidedAt
                )
                updateThreadTimestamp(resolution.decidedAt, for: invocation.threadID)
                try await persistState()
                return denied
            }
        }

        let toolWaitStartedAt = Date()
        try setPendingState(
            .toolWait(
                AgentPendingToolWaitState(
                    invocationID: invocation.id,
                    turnID: invocation.turnID,
                    toolName: invocation.toolName,
                    startedAt: toolWaitStartedAt
                )
            ),
            for: invocation.threadID
        )
        try setLatestToolState(
            latestToolState(for: invocation, result: nil, updatedAt: toolWaitStartedAt),
            for: invocation.threadID
        )
        try await setThreadStatus(.waitingForToolResult, for: invocation.threadID)
        yieldThreadStatusChanged(invocation.threadID, .waitingForToolResult)

        let result = await toolRegistry.execute(invocation, session: session)
        let resultDate = Date()
        try setLatestToolState(
            latestToolState(for: invocation, result: result, updatedAt: resultDate),
            for: invocation.threadID
        )
        if let session = result.session, !session.isTerminal {
            try setPendingState(
                .toolWait(
                    AgentPendingToolWaitState(
                        invocationID: invocation.id,
                        turnID: invocation.turnID,
                        toolName: invocation.toolName,
                        startedAt: toolWaitStartedAt,
                        sessionID: session.sessionID,
                        sessionStatus: session.status,
                        metadata: session.metadata,
                        resumable: session.resumable
                    )
                ),
                for: invocation.threadID
            )
        } else {
            try setPendingState(nil, for: invocation.threadID)
            appendHistoryItem(
                .toolResult(
                    AgentToolResultRecord(
                        threadID: invocation.threadID,
                        turnID: invocation.turnID,
                        result: result,
                        completedAt: resultDate
                    )
                ),
                threadID: invocation.threadID,
                createdAt: resultDate
            )
        }
        updateThreadTimestamp(resultDate, for: invocation.threadID)
        try await persistState()
        return result
    }
}
