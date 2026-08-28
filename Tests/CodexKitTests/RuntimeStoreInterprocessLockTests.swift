import CodexKit
import Foundation
import XCTest

final class RuntimeStoreInterprocessLockTests: XCTestCase {
    func testLockExcludesASeparateProcess() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexKitProcessLock-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let attachmentRoot = directory
            .appendingPathComponent("state", isDirectory: true)
            .appendingPathComponent("attachments", isDirectory: true)
        let markerURL = directory.appendingPathComponent("child-acquired")
        let lockURL = attachmentRoot.deletingLastPathComponent()
            .appendingPathComponent(".codexkit-runtime.lock")
        let lock = try await RuntimeStoreInterprocessLock.acquire(for: attachmentRoot)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "python3",
            "-c",
            "import fcntl, pathlib, sys; f=open(sys.argv[1], 'a+'); fcntl.flock(f, fcntl.LOCK_EX); pathlib.Path(sys.argv[2]).write_text('acquired')",
            lockURL.path,
            markerURL.path,
        ]
        try process.run()
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertTrue(process.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))

        lock.release()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(try String(contentsOf: markerURL, encoding: .utf8), "acquired")
    }

    func testExclusiveLeaseRejectsPartialExpansionInsteadOfDeadlocking() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexKitNestedLease-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory
            .appendingPathComponent("first", isDirectory: true)
            .appendingPathComponent("attachments", isDirectory: true)
        let second = directory
            .appendingPathComponent("second", isDirectory: true)
            .appendingPathComponent("attachments", isDirectory: true)

        do {
            _ = try await RuntimeStoreMutationCoordinator.shared.performExclusively(
                for: [first]
            ) {
                try await RuntimeStoreMutationCoordinator.shared.performExclusively(
                    for: [first, second]
                ) {
                    42
                }
            }
            XCTFail("Expected a partial lease expansion to be rejected.")
        } catch let error as RuntimeStoreMutationCoordinatorError {
            XCTAssertEqual(error, .exclusiveLeaseExpansionUnsupported)
        }
    }

    func testSymlinkAliasesResolveToTheSameLock() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexKitSymlinkLock-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let realDirectory = directory.appendingPathComponent("real", isDirectory: true)
        let aliasDirectory = directory.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: aliasDirectory, withDestinationURL: realDirectory)

        let realRoot = realDirectory
            .appendingPathComponent("state", isDirectory: true)
            .appendingPathComponent("attachments", isDirectory: true)
        let aliasRoot = aliasDirectory
            .appendingPathComponent("state", isDirectory: true)
            .appendingPathComponent("attachments", isDirectory: true)

        XCTAssertEqual(
            RuntimeStoreInterprocessLock.lockURL(for: realRoot),
            RuntimeStoreInterprocessLock.lockURL(for: aliasRoot)
        )
    }
}
