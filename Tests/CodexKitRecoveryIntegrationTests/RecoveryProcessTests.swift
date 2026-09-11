import CodexKit
import Foundation
import RecoveryIntegrationSupport
import XCTest

@MainActor
final class RecoveryProcessTests: XCTestCase {
    func testActualProcessCrashesAroundHostCommitAndAcknowledgement() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executable = root.appendingPathComponent(".build/debug/RecoveryIntegrationFixture")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (mode, expectedExit) in [("seed", Int32(73)), ("commit-crash", 74), ("finish", 0), ("finish", 0)] {
            let process = Process()
            process.executableURL = executable
            process.arguments = [mode, directory.path]
            let output = Pipe()
            process.standardOutput = output; process.standardError = output
            try process.run()
            process.waitUntilExit()
            let details = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            XCTAssertEqual(process.terminationStatus, expectedExit, details)
        }
        let host = try FixtureHostStore(directory: directory)
        let job = await host.job("news")
        XCTAssertEqual(job?.commitCount, 1)
        let requests = try String(contentsOf: directory.appendingPathComponent("requests.log"), encoding: .utf8)
        XCTAssertEqual(requests.split(separator: "\n").count, 1)
    }
}
