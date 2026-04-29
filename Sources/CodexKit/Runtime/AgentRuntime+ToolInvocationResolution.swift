import Foundation

extension AgentRuntime {
    func resolveToolInvocation(
        _ invocation: ToolInvocation,
        session: ChatGPTSession,
        storesTurnState: Bool = true,
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    ) async throws -> ToolResultEnvelope {
        try await resolveToolInvocationImpl(
            invocation,
            session: session,
            storesTurnState: storesTurnState,
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
        storesTurnState: Bool = true,
        continuation: AsyncThrowingStream<AgentStructuredStreamEvent<Output>, Error>.Continuation
    ) async throws -> ToolResultEnvelope {
        try await resolveToolInvocationImpl(
            invocation,
            session: session,
            storesTurnState: storesTurnState,
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
        storesTurnState: Bool,
        yieldThreadStatusChanged: (String, AgentThreadStatus) -> Void,
        yieldApprovalRequested: (ApprovalRequest) -> Void,
        yieldApprovalResolved: (ApprovalResolution) -> Void
    ) async throws -> ToolResultEnvelope {
        logger.info(
            .tools,
            "Resolving tool invocation.",
            metadata: [
                "thread_id": invocation.threadID,
                "turn_id": invocation.turnID,
                "tool_name": invocation.toolName
            ]
        )
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

            if storesTurnState {
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
            }
            yieldApprovalRequested(approval)
            logger.info(
                .approvals,
                "Tool invocation requires approval.",
                metadata: [
                    "thread_id": invocation.threadID,
                    "tool_name": invocation.toolName,
                    "request_id": approval.id
                ]
            )

            let decision = try await approvalCoordinator.requestApproval(approval)
            let resolution = ApprovalResolution(
                requestID: approval.id,
                threadID: approval.threadID,
                turnID: approval.turnID,
                decision: decision
            )
            if storesTurnState {
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
            }
            yieldApprovalResolved(resolution)
            logger.info(
                .approvals,
                "Tool approval resolved.",
                metadata: [
                    "thread_id": invocation.threadID,
                    "tool_name": invocation.toolName,
                    "decision": resolution.decision.rawValue
                ]
            )

            guard decision == .approved else {
                let denied = ToolResultEnvelope.denied(invocation: invocation)
                if storesTurnState {
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
                }
                return denied
            }
        }

        let toolWaitStartedAt = Date()
        logger.info(
            .tools,
            "Executing tool invocation.",
            metadata: [
                "thread_id": invocation.threadID,
                "turn_id": invocation.turnID,
                "invocation_id": invocation.id,
                "tool_name": invocation.toolName
            ]
        )
        if storesTurnState {
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
        }

        let result = await toolRegistry.execute(invocation, session: session)
        let resultDate = Date()
        logger.info(
            .tools,
            "Tool invocation completed.",
            metadata: [
                "thread_id": invocation.threadID,
                "turn_id": invocation.turnID,
                "invocation_id": invocation.id,
                "tool_name": invocation.toolName,
                "success": "\(result.errorMessage == nil)",
                "duration_ms": "\(Int(resultDate.timeIntervalSince(toolWaitStartedAt) * 1000))",
                "has_follow_up_session": "\(result.session?.isTerminal == false)"
            ]
        )
        if storesTurnState {
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
        }
        return result
    }
}
