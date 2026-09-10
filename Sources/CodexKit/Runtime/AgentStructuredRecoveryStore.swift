import Darwin
import Foundation

/// Opt-in local storage of frozen request input and completed results. Keep in Application Support,
/// not a purgeable cache. The host owns retention and acknowledges after its gameplay commit.
/// Cross-instance/process locks prevent concurrent generation for the same handle.
public struct AgentStructuredRecoveryStore: Sendable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory.standardizedFileURL }

    func acquire(_ handle: AgentStructuredRecoveryHandle) throws -> RecoveryFileLease {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent(handle.id.uuidString + ".lock")
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            path.map { open($0, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR) } ?? -1
        }
        guard descriptor >= 0 else { throw AgentRecoveryError.stateUnavailable }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw AgentRecoveryError.busy
        }
        return RecoveryFileLease(descriptor: descriptor)
    }

    func load(_ handle: AgentStructuredRecoveryHandle) throws -> AgentStructuredRecoveryRecord {
        let url = recordURL(handle)
        guard FileManager.default.fileExists(atPath: url.path) else { throw AgentRecoveryError.stateUnavailable }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue <= 128 * 1_024 * 1_024,
              attributes[.type] as? FileAttributeType == .typeRegular else { throw AgentRecoveryError.stateInvalid }
        let record: AgentStructuredRecoveryRecord
        do { record = try JSONDecoder().decode(AgentStructuredRecoveryRecord.self, from: Data(contentsOf: url)) }
        catch { throw AgentRecoveryError.stateInvalid }
        guard record.version == 1, record.handle == handle, record.maximumAttempts > 0,
              record.attemptsUsed >= 0, record.attemptsUsed <= record.maximumAttempts,
              (record.state == .completed) == (record.completedPayload != nil) else { throw AgentRecoveryError.stateInvalid }
        return record
    }

    func save(_ record: AgentStructuredRecoveryRecord) throws {
        let data = try JSONEncoder().encode(record)
        guard data.count <= 128 * 1_024 * 1_024 else { throw AgentRecoveryError.stateInvalid }
        let url = recordURL(record.handle)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func remove(_ handle: AgentStructuredRecoveryHandle) throws {
        try FileManager.default.removeItem(at: recordURL(handle))
        // Keep the lock inode: deleting it permits two processes to lock different files for one handle.
    }

    private func recordURL(_ handle: AgentStructuredRecoveryHandle) -> URL {
        directory.appendingPathComponent(handle.id.uuidString + ".json")
    }
}

final class RecoveryFileLease: Sendable {
    let descriptor: Int32
    init(descriptor: Int32) { self.descriptor = descriptor }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}
