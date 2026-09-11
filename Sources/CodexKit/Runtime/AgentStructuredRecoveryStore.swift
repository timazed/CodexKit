import Darwin
import Foundation

/// Explicit opt-in storage in Application Support. It never evicts an unacknowledged completion.
/// Each directory is a local device store, not a distributed or cloud-synchronized job queue.
public struct AgentStructuredRecoveryStore: Sendable {
    public let directory: URL
    public let maximumBytes: Int
    public init(directory: URL, maximumBytes: Int = 512 * 1_024 * 1_024) {
        self.directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        self.maximumBytes = max(0, maximumBytes)
    }

    func acquire(_ handle: AgentStructuredRecoveryHandle) throws -> RecoveryFileLease {
        try acquireLock(handle.id.uuidString + ".lock")
    }
    func acquireLock(_ name: String, waiting: Bool = false) throws -> RecoveryFileLease {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent(name)
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            path.map { open($0, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR) } ?? -1
        }
        guard descriptor >= 0 else { throw AgentRecoveryError.stateUnavailable }
        guard flock(descriptor, LOCK_EX | (waiting ? 0 : LOCK_NB)) == 0 else {
            close(descriptor)
            throw AgentRecoveryError.busy
        }
        return RecoveryFileLease(descriptor: descriptor)
    }

    func load(_ handle: AgentStructuredRecoveryHandle) throws -> AgentStructuredRecoveryRecord {
        if try disposition(handle) != nil { throw AgentRecoveryError.stateUnavailable }
        let data = try readData(url(handle))
        let envelope: RecordVersion
        do { envelope = try JSONDecoder().decode(RecordVersion.self, from: data) }
        catch { throw AgentRecoveryError.stateInvalid }
        guard [1, 2].contains(envelope.version) else { throw AgentRecoveryError.unsupportedRecordVersion }
        let record: AgentStructuredRecoveryRecord
        do { record = try JSONDecoder().decode(AgentStructuredRecoveryRecord.self, from: data) }
        catch { throw AgentRecoveryError.stateInvalid }
        guard record.handle == handle, record.maximumAttempts > 0, record.attemptsUsed >= 0,
              record.attemptsUsed <= record.maximumAttempts,
              (record.state == .completed) == (record.completedPayload != nil) else { throw AgentRecoveryError.stateInvalid }
        try record.preparedRequest?.validate()
        if let prepared = record.preparedRequest, prepared.endpoint != record.endpoint { throw AgentRecoveryError.stateInvalid }
        return record
    }

    func save(_ record: AgentStructuredRecoveryRecord) throws {
        guard try disposition(record.handle) == nil else { throw AgentRecoveryError.stateUnavailable }
        var record = record
        record.updatedAt = Date()
        let data = try JSONEncoder().encode(record)
        guard data.count <= 128 * 1_024 * 1_024 else { throw AgentRecoveryError.storageLimitExceeded }
        // Serialize quota admission across independent operations. No payload is deleted to make room.
        let lease = try acquireLock("quota.lock", waiting: true)
        defer { withExtendedLifetime(lease) {} }
        let destination = url(record.handle)
        let files = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])
        var bytes = data.count
        for file in files where file.pathExtension == "json" && file != destination {
            bytes += (try file.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
            if bytes > maximumBytes { throw AgentRecoveryError.storageLimitExceeded }
        }
        guard bytes <= maximumBytes else { throw AgentRecoveryError.storageLimitExceeded }
        try write(data, to: destination)
    }

    func readData(_ url: URL) throws -> Data {
        guard FileManager.default.fileExists(atPath: url.path) else { throw AgentRecoveryError.stateUnavailable }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue <= 128 * 1_024 * 1_024,
              attributes[.type] as? FileAttributeType == .typeRegular else { throw AgentRecoveryError.stateInvalid }
        return try Data(contentsOf: url)
    }

    /// Atomic visibility plus fsync before rename. Existing data survives a failed write.
    func write(_ data: Data, to destination: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent("." + UUID().uuidString + ".tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: [.completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        let file = try FileHandle(forWritingTo: temporary)
        do { try file.synchronize(); try file.close() }
        catch { try? file.close(); throw error }
        guard rename(temporary.path, destination.path) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        let descriptor = open(directory.path, O_RDONLY | O_CLOEXEC)
        if descriptor >= 0 { _ = fsync(descriptor); close(descriptor) }
    }

    func disposition(_ handle: AgentStructuredRecoveryHandle) throws -> RecoveryDisposition? {
        let path = url(handle, suffix: ".disposition.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let value = try JSONDecoder().decode(RecoveryDisposition.self, from: readData(path))
        guard value.handle == handle else { throw AgentRecoveryError.stateInvalid }
        return value
    }
    func dispose(_ record: AgentStructuredRecoveryRecord, state: AgentStructuredRecoveryStatus.State) throws {
        let marker = RecoveryDisposition(handle: record.handle, binding: record.binding, state: state,
            disposedAt: Date(), previousOperationID: record.previousOperationID, successorID: record.successorID,
            scope: record.scope)
        try write(JSONEncoder().encode(marker), to: url(record.handle, suffix: ".disposition.json"))
        try remove(record.handle)
    }
    func remove(_ handle: AgentStructuredRecoveryHandle) throws {
        let path = url(handle)
        if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
        // Lock inodes remain: removing them can give concurrent processes different locks for one operation.
    }
    func url(_ handle: AgentStructuredRecoveryHandle, suffix: String = ".json") -> URL {
        directory.appendingPathComponent(handle.id.uuidString + suffix)
    }
    func isExecuting(_ handle: AgentStructuredRecoveryHandle) throws -> Bool {
        do { let lease = try acquire(handle); withExtendedLifetime(lease) {}; return false }
        catch AgentRecoveryError.busy { return true }
    }
    private struct RecordVersion: Decodable { let version: Int }
}

struct RecoveryDisposition: Codable, Sendable {
    let handle: AgentStructuredRecoveryHandle
    let binding: ChatGPTSessionBinding
    let state: AgentStructuredRecoveryStatus.State
    let disposedAt: Date
    let previousOperationID: UUID?
    let successorID: UUID?
    let scope: String?
    var status: AgentStructuredRecoveryStatus {
        .init(state: state, operationID: handle.id, previousOperationID: previousOperationID,
              successorID: successorID, scope: scope)
    }
}

final class RecoveryFileLease: Sendable {
    let descriptor: Int32
    init(descriptor: Int32) { self.descriptor = descriptor }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}
