import Darwin
import Foundation

/// Extends runtime-store mutation serialization across processes. The lock
/// covers both the database mutation and attachment sidecar reconciliation.
package struct RuntimeStoreInterprocessLock: Sendable {
    private let fileDescriptor: Int32

    package static func acquire(for attachmentRootURL: URL) async throws -> Self {
        try await Task.detached(priority: nil) {
            try acquireSynchronously(for: attachmentRootURL)
        }.value
    }

    package func release() {
        _ = flock(fileDescriptor, LOCK_UN)
        _ = close(fileDescriptor)
    }

    package static func lockURL(for attachmentRootURL: URL) -> URL {
        canonicalRootURL(for: attachmentRootURL)
            .deletingLastPathComponent()
            .appendingPathComponent(".codexkit-runtime.lock", isDirectory: false)
            .standardizedFileURL
    }

    package static func canonicalRootURL(for url: URL) -> URL {
        var existingAncestor = url.standardizedFileURL
        var missingComponents: [String] = []
        while !FileManager.default.fileExists(atPath: existingAncestor.path),
              existingAncestor.path != "/" {
            missingComponents.append(existingAncestor.lastPathComponent)
            existingAncestor.deleteLastPathComponent()
        }
        var canonical = existingAncestor.resolvingSymlinksInPath()
        for component in missingComponents.reversed() {
            canonical.appendPathComponent(component)
        }
        return canonical.standardizedFileURL
    }

    private static func acquireSynchronously(
        for attachmentRootURL: URL
    ) throws -> Self {
        let lockURL = lockURL(for: attachmentRootURL)
        try FileManager.default.createDirectory(
            at: lockURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let fileDescriptor = lockURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return open(path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        }
        guard fileDescriptor >= 0 else {
            throw POSIXError(Self.currentPOSIXErrorCode())
        }

        while flock(fileDescriptor, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            let error = POSIXError(Self.currentPOSIXErrorCode())
            _ = close(fileDescriptor)
            throw error
        }
        return Self(fileDescriptor: fileDescriptor)
    }

    private static func currentPOSIXErrorCode() -> POSIXErrorCode {
        POSIXErrorCode(rawValue: errno) ?? .EIO
    }
}
