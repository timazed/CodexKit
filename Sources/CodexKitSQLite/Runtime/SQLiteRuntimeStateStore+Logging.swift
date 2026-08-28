import CodexKit

extension SQLiteRuntimeStateStore {
    func operationTypeSummary(
        for operations: [AgentStoreWriteOperation]
    ) -> String {
        let counts = Dictionary(operations.map(operationTypeLabel(for:)), uniquingKeysWith: +)
        return counts
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ",")
    }

    func operationTypeLabel(
        for operation: AgentStoreWriteOperation
    ) -> (String, Int) {
        switch operation {
        case .upsertThread:
            return ("upsert_thread", 1)
        case .upsertSummary:
            return ("upsert_summary", 1)
        case .appendHistoryItems:
            return ("append_history", 1)
        case .restoreHistoryItems:
            return ("restore_history", 1)
        case .setPendingState:
            return ("set_pending_state", 1)
        case .setPartialStructuredSnapshot:
            return ("set_partial_snapshot", 1)
        case .upsertToolSession:
            return ("upsert_tool_session", 1)
        case .redactHistoryItems:
            return ("redact_history", 1)
        case .deleteThread:
            return ("delete_thread", 1)
        case .upsertThreadContextState:
            return ("upsert_context_state", 1)
        case .appendCompactionMarker:
            return ("append_compaction_marker", 1)
        case .deleteThreadContextState:
            return ("delete_context_state", 1)
        }
    }
}
