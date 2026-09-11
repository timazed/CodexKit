import Foundation

public struct AgentRecoveryCleanupResult: Sendable {
    public var removed: [UUID] = []
    public var skipped: [UUID] = []
    public init() {}
}

extension AgentStructuredRecoveryStore {
    func handles() throws -> [AgentStructuredRecoveryHandle] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        let ids = Set(urls.compactMap { url -> UUID? in
            guard url.pathExtension == "json" else { return nil }
            return UUID(uuidString: String(url.lastPathComponent.prefix(36)))
        })
        return ids.sorted { $0.uuidString < $1.uuidString }.map { .init(id: $0) }
    }

    /// Explicit host maintenance authority. May be used after sign-out without renewing old credentials.
    /// Unreadable records and active operations are preserved and reported. No recovery budget is recreated.
    public func purgeAccount(_ binding: ChatGPTSessionBinding, scope: String? = nil) throws -> AgentRecoveryCleanupResult {
        var result = AgentRecoveryCleanupResult()
        for handle in try handles() {
            do {
                let lease = try acquire(handle)
                defer { withExtendedLifetime(lease) {} }
                if let marker = try disposition(handle) {
                    guard marker.binding == binding, scope == nil || marker.scope == scope else { continue }
                } else {
                    let record = try load(handle)
                    guard record.binding == binding, scope == nil || record.scope == scope else { continue }
                }
                try eraseContentAndMarkers(handle)
                result.removed.append(handle.id)
            } catch { result.skipped.append(handle.id) }
        }
        return result
    }

    /// Only acknowledged/abandoned records are age-eligible. Unacknowledged receipts are never age-evicted.
    public func cleanupDisposed(before date: Date, for binding: ChatGPTSessionBinding) throws -> AgentRecoveryCleanupResult {
        var result = AgentRecoveryCleanupResult()
        for handle in try handles() {
            do {
                let lease = try acquire(handle)
                defer { withExtendedLifetime(lease) {} }
                guard let marker = try disposition(handle), marker.binding == binding, marker.disposedAt < date else { continue }
                try eraseContentAndMarkers(handle)
                result.removed.append(handle.id)
            } catch { result.skipped.append(handle.id) }
        }
        return result
    }

    private func eraseContentAndMarkers(_ handle: AgentStructuredRecoveryHandle) throws {
        try remove(handle)
        for suffix in [".disposition.json", ".control.json"] {
            let path = url(handle, suffix: suffix)
            if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
        }
        // The small lock inodes intentionally remain until the host retires the entire inactive store directory.
    }
}
