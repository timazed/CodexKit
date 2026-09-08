@testable import CodexKit
import Foundation
import XCTest

final class StorageLockCancellationTests: XCTestCase {
    func testCancelledWaiterStopsBeforeTheLockOwnerReleases() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("attachments")
        let held = try await RuntimeStoreInterprocessLock.acquire(for: root)
        let state = LockCancellationState()
        let started = AgentTurnReadiness()
        let waiter = Task {
            await started.resolve(.success(()))
            do {
                let lock = try await RuntimeStoreInterprocessLock.acquire(for: root)
                lock.release()
                await state.finish("acquired")
            } catch is CancellationError {
                await state.finish("cancelled")
            } catch {
                await state.finish("other_error")
            }
        }
        try await started.wait()
        try await Task.sleep(for: .milliseconds(100))
        waiter.cancel()
        try await Task.sleep(for: .milliseconds(200))
        let whileHeld = await state.result
        // Release before asserting, so a regression never leaves a blocked waiter.
        held.release()
        await waiter.value
        let final = await state.result
        XCTAssertEqual(whileHeld, "cancelled")
        XCTAssertEqual(final, "cancelled")
    }
}

private actor LockCancellationState {
    var result: String?
    func finish(_ result: String) { self.result = result }
}
