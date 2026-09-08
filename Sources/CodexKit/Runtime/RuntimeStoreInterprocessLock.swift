import Darwin
import Foundation

/// Extends runtime-store mutation serialization across processes. The lock
/// covers both the database mutation and attachment sidecar reconciliation.
package struct RuntimeStoreInterprocessLock: Sendable {
    private let fileDescriptor: Int32

    package static func acquire(for attachmentRootURL: URL) async throws -> Self {
        try Task.checkCancellation()
        let fileDescriptor = try openLockFile(for: attachmentRootURL)
        var transferred = false
        defer { if !transferred { _ = close(fileDescriptor) } }
        var delay = 1
        while true {
            try Task.checkCancellation()
            if flock(fileDescriptor, LOCK_EX | LOCK_NB) == 0 {
                try Task.checkCancellation()
                transferred = true
                return Self(fileDescriptor: fileDescriptor)
            }
            let code = errno
            if code == EINTR { continue }
            guard code == EWOULDBLOCK || code == EAGAIN else {
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            // Suspend while contended; a blocking flock would occupy a Swift
            // executor worker and would not respond to task cancellation.
            try await Task.sleep(for: .milliseconds(delay))
            delay = min(delay * 2, 25)
        }
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

    private static func openLockFile(
        for attachmentRootURL: URL
    ) throws -> Int32 {
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

        return fileDescriptor
    }

    private static func currentPOSIXErrorCode() -> POSIXErrorCode {
        POSIXErrorCode(rawValue: errno) ?? .EIO
    }
}
