import Foundation

extension AgentRuntime {
    func resolveToolInvocation(
        _ invocation: ToolInvocation,
        session: ChatGPTSession,
        registration: ToolRegistry.Entry?,
        storesTurnState: Bool,
        sink: AgentToolEventSink
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
        if let definition = registration?.definition,
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
                try appendHistoryItem(
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
                try await sink.yield(.threadStatusChanged(threadID: invocation.threadID, status: .waitingForApproval))
            }
            try await sink.yield(.approvalRequested(approval))
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
            try Task.checkCancellation()
            let resolution = ApprovalResolution(
                requestID: approval.id,
                threadID: approval.threadID,
                turnID: approval.turnID,
                decision: decision
            )
            if storesTurnState {
                try appendHistoryItem(
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
            try await sink.yield(.approvalResolved(resolution))
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
                    try appendHistoryItem(
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
            try await sink.yield(.threadStatusChanged(threadID: invocation.threadID, status: .waitingForToolResult))
        }

        try Task.checkCancellation()
        let result: ToolResultEnvelope
        if let registration {
            try await validateActiveAuthentication(session)
            result = await registration.execute(invocation, session: session)
            try await validateActiveAuthentication(session)
        } else {
            result = .failure(invocation: invocation, message: "No tool named \(invocation.toolName) was registered for this turn.")
        }
        try Task.checkCancellation()
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
                parallelToolWaits[invocation.turnID]?[invocation.id] = nil
                let remaining = parallelToolWaits[invocation.turnID]?.values.sorted { $0.invocationID < $1.invocationID }.first
                try setPendingState(remaining.map(AgentThreadPendingState.toolWait), for: invocation.threadID)
                try appendHistoryItem(
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
