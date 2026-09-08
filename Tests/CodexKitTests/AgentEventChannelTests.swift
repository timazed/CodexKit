@testable import CodexKit
import XCTest

final class AgentEventChannelTests: XCTestCase {
    func testBackpressurePreservesOrderAndReservedTerminalEvents() async throws {
        let channel = AgentEventChannel<Int>.makeStream(capacity: 2)
        let producer = Task {
            for value in 0..<10_000 { try await channel.continuation.yield(value) }
            channel.continuation.finish(finalElements: [10_000, 10_001])
        }
        await waitUntilBlocked(channel.continuation)
        XCTAssertEqual(channel.continuation.diagnostics.buffered, 2)
        var received = 0
        for try await value in channel.stream {
            XCTAssertEqual(value, received)
            received += 1
        }
        try await producer.value
        XCTAssertEqual(received, 10_002)
        XCTAssertEqual(channel.continuation.diagnostics.peakBuffered, 2)
    }

    func testFullQueueStillDeliversFailureAfterProducerCancellation() async throws {
        let channel = AgentEventChannel<Int>.makeStream(capacity: 1)
        try await channel.continuation.yield(1)
        let blocked = Task { try await channel.continuation.yield(2) }
        await waitUntilBlocked(channel.continuation)
        blocked.cancel()
        do { try await blocked.value; XCTFail("Expected producer cancellation") } catch is CancellationError { }
        channel.continuation.finish(throwing: AgentRuntimeError.executionLimitExceeded(.duration), finalElements: [3, 4])
        var values: [Int] = []
        do {
            for try await value in channel.stream { values.append(value) }
            XCTFail("Expected the terminal error")
        } catch {
            XCTAssertEqual((error as? AgentRuntimeError)?.executionLimit, .duration)
        }
        XCTAssertEqual(values, [1, 3, 4])
    }

    func testCancellingOneProducerDoesNotCloseTheQueue() async throws {
        let channel = AgentEventChannel<Int>.makeStream(capacity: 1)
        try await channel.continuation.yield(1)
        let cancelled = Task { try await channel.continuation.yield(2) }
        await waitUntilBlocked(channel.continuation)
        cancelled.cancel()
        do { try await cancelled.value; XCTFail("Expected cancellation") } catch is CancellationError { }
        let remaining = Task {
            try await channel.continuation.yield(3)
            channel.continuation.finish()
        }
        var values: [Int] = []
        for try await value in channel.stream { values.append(value) }
        try await remaining.value
        XCTAssertEqual(values, [1, 3])
    }

    func testDroppingTheStreamReleasesBlockedProducers() async throws {
        var pair: (stream: AsyncThrowingStream<Int, Error>, continuation: AgentEventChannel<Int>)?
            = AgentEventChannel.makeStream(capacity: 1)
        let channel = pair!.continuation
        let cancelled = expectation(description: "producer cancellation handler")
        channel.onCancellation { cancelled.fulfill() }
        try await channel.yield(1)
        let producer = Task { try await channel.yield(2) }
        await waitUntilBlocked(channel)
        pair = nil
        await fulfillment(of: [cancelled], timeout: 2)
        do { try await producer.value; XCTFail("Expected producer release") } catch is CancellationError { }
        XCTAssertEqual(channel.diagnostics.buffered, 0)
    }

    func testConsumerCancellationClosesTheQueue() async throws {
        let channel = AgentEventChannel<Int>.makeStream(capacity: 1)
        let started = expectation(description: "consumer started")
        let cancelled = expectation(description: "channel cancelled")
        channel.continuation.onCancellation { cancelled.fulfill() }
        let consumer = Task {
            started.fulfill()
            for try await _ in channel.stream { }
        }
        await fulfillment(of: [started], timeout: 2)
        consumer.cancel()
        await fulfillment(of: [cancelled], timeout: 2)
        _ = try? await consumer.value
        do { try await channel.continuation.yield(1); XCTFail("Expected closed queue") } catch is CancellationError { }
    }

    private func waitUntilBlocked<Value>(_ channel: AgentEventChannel<Value>) async {
        for _ in 0..<1_000 {
            if channel.diagnostics.waitingProducers > 0 { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Expected a producer to wait for bounded capacity")
    }
}
