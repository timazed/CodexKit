struct SQLiteThreadActivationMetrics: Equatable, Sendable {
    let fetchedHistoryRowCount: Int
    let decodedHistoryRowCount: Int
    let decodedHistoryByteCount: Int
    let usedPersistedContextState: Bool
}
