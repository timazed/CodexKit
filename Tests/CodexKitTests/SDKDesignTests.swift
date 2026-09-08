@testable import CodexKit
import Combine
import XCTest

final class SDKDesignTests: XCTestCase {
    func testHostSessionProviderOwnsAuthenticationWithoutKeychainConfiguration() async throws {
        let provider = DesignSessionProvider()
        let originalSession = await provider.currentSession()
        let config = AgentRuntime.Configuration(sessionProvider: provider, backend: DesignBackend(),
            approvalPresenter: AutoApprovalPresenter(), stateStore: InMemoryRuntimeStateStore())
        XCTAssertNil(config.authProvider)
        XCTAssertNil(config.secureStore)
        let runtime = try AgentRuntime(configuration: config)
        _ = try await runtime.restore()
        let restored = await runtime.currentSession()
        XCTAssertEqual(restored, originalSession)
        let thread = try await runtime.createThread()
        let result = try await runtime.send(Request(text: "Go"), in: thread.id)
        XCTAssertEqual(result, "Done")
        try await runtime.signOut()
        let signedOut = await runtime.currentSession()
        XCTAssertNil(signedOut)
        _ = try await runtime.signIn()
        _ = try await runtime.useSession(demoSession())
        let actions = await provider.actions
        XCTAssertEqual(actions, ["signOut", "signIn", "useSession"])
    }

    func testReadOnlyProviderExplicitlyRejectsSessionManagement() async throws {
        let runtime = try makeRuntime(provider: DesignReadOnlyProvider())
        do { _ = try await runtime.signIn(); XCTFail("Expected unsupported management") }
        catch { XCTAssertEqual((error as? AgentRuntimeError)?.code, "session_management_unsupported") }
        let thread = try await runtime.createThread()
        let result = try await runtime.send(Request(text: "Go"), in: thread.id)
        XCTAssertEqual(result, "Done")
    }

    func testReadinessDoesNotRequireDrainingAFullPublicQueue() async throws {
        let runtime = try makeRuntime()
        let thread = try await runtime.createThread()
        let execution = try await runtime.start(Request(text: "Go"), in: thread.id)
        XCTAssertEqual(execution.threadID, thread.id)
        try await execution.waitUntilReady()
        var completed = false
        for try await event in execution.events { if case .turnCompleted = event { completed = true } }
        XCTAssertTrue(completed)
        do { try await execution.steer("Too late"); XCTFail("Completed handles must reject input") }
        catch { XCTAssertEqual((error as? AgentRuntimeError)?.code, "turn_not_active") }
    }

    func testCancelledReadinessWaiterDoesNotCancelExecutionOrOtherWaiters() async throws {
        let gate = AgentTurnReadiness()
        let runtime = try makeRuntime(backend: DesignBackend(readiness: { try await gate.wait() }))
        let thread = try await runtime.createThread()
        let execution = try await runtime.start(Request(text: "Go"), in: thread.id)
        let waiter = Task { try await execution.waitUntilReady() }
        waiter.cancel()
        do { try await waiter.value; XCTFail("Expected cancelled wait") } catch is CancellationError {}
        await gate.resolve(.success(()))
        try await execution.waitUntilReady()
        for try await _ in execution.events {}
    }

    func testStartupFailureReachesBothReadinessAndEvents() async throws {
        let failure = AgentRuntimeError(code: "startup_failure", message: "Failure")
        let runtime = try makeRuntime(backend: DesignBackend(readiness: { throw failure }))
        let thread = try await runtime.createThread()
        let execution = try await runtime.start(Request(text: "Go"), in: thread.id)
        do { try await execution.waitUntilReady(); XCTFail("Expected failed readiness") }
        catch { XCTAssertEqual(error as? AgentRuntimeError, failure) }
        do { for try await _ in execution.events {}; XCTFail("Expected failed events") }
        catch { XCTAssertEqual(error as? AgentRuntimeError, failure) }
        let active = await runtime.activeTurnID(in: thread.id)
        XCTAssertNil(active)
    }

    func testEphemeralHandleCancellationLeavesPersistentExecutionRunning() async throws {
        let gate = AgentTurnReadiness()
        let runtime = try makeRuntime(backend: DesignBackend(readiness: { try await gate.wait() }))
        let thread = try await runtime.createThread()
        let persistent = try await runtime.start(Request(text: "Persistent"), in: thread.id)
        let ephemeral = try await runtime.start(Request(text: "Transient", executionMode: .ephemeral), in: thread.id)
        XCTAssertNotEqual(persistent.id, ephemeral.id)
        ephemeral.cancel()
        do { for try await _ in ephemeral.events {}; XCTFail("Expected ephemeral cancellation") }
        catch is CancellationError {}
        await gate.resolve(.success(()))
        try await persistent.waitUntilReady()
        for try await _ in persistent.events {}
        let messages = await runtime.messages(for: thread.id)
        XCTAssertEqual(messages.filter { $0.role == .user }.map(\.text), ["Persistent"])
    }

    func testStructuredHandlePreservesTypedOutput() async throws {
        let runtime = try makeRuntime()
        let thread = try await runtime.createThread()
        let execution = try await runtime.start(Request(text: "Go"), in: thread.id, response: DesignOutput.self)
        try await execution.waitUntilReady()
        var output: DesignOutput?
        for try await event in execution.events {
            if case let .structuredOutputCommitted(value) = event { output = value }
        }
        XCTAssertEqual(output?.value, "Done")
    }

    func testLatestAsyncObservationCoalescesSnapshotsAndSurvivesDeactivation() async throws {
        let center = AgentRuntimeObservationCenter()
        let publisher = AgentRuntimeObservationPublisher { center.messagePublisher(for: "thread") }
        let values = publisher.values(buffering: .latest)
        for i in 0..<10 {
            center.send(.messagesChanged(threadID: "thread", messages: [.init(threadID: "thread", role: .user, text: "\(i)")]))
        }
        var iterator = values.makeAsyncIterator()
        let latest = try await iterator.next()
        XCTAssertEqual(latest?.first?.text, "9")
        center.deactivateThread(id: "thread", activeThreads: [])
        let cleared = try await iterator.next()
        XCTAssertEqual(cleared, [])
        center.send(.messagesChanged(threadID: "thread", messages: [.init(threadID: "thread", role: .user, text: "Resumed")]))
        let resumed = try await iterator.next()
        XCTAssertEqual(resumed?.first?.text, "Resumed")
    }

    func testNotificationOverflowFailsAfterAdmittedValues() async throws {
        let center = AgentRuntimeObservationCenter()
        let publisher = AgentRuntimeObservationPublisher { center.publisher }
        let values = publisher.values(buffering: .buffered(limit: 2))
        for i in 0..<3 { center.send(.threadDeleted(threadID: "\(i)")) }
        var received: [String] = []
        do {
            for try await value in values { if case let .threadDeleted(id) = value { received.append(id) } }
            XCTFail("Expected overflow")
        } catch { XCTAssertEqual((error as? AgentRuntimeError)?.code, "observation_buffer_overflow") }
        XCTAssertEqual(received, ["0", "1"])
    }

    func testDroppingAsyncObservationCancelsItsCombineSubscription() async throws {
        let cancelled = expectation(description: "subscription released")
        let center = AgentRuntimeObservationCenter()
        let publisher = AgentRuntimeObservationPublisher {
            center.publisher.handleEvents(receiveCancel: { cancelled.fulfill() }).eraseToAnyPublisher()
        }
        var values: AgentObservationSequence<AgentRuntimeObservation>? = publisher.values
        XCTAssertNotNil(values)
        values = nil
        await fulfillment(of: [cancelled], timeout: 1)
    }

    func testCancellingAsyncObservationUnsubscribes() async throws {
        let cancelled = expectation(description: "subscription cancelled")
        let center = AgentRuntimeObservationCenter()
        let publisher = AgentRuntimeObservationPublisher {
            center.publisher.handleEvents(receiveCancel: { cancelled.fulfill() }).eraseToAnyPublisher()
        }
        let values = publisher.values
        let consumer = Task { for try await _ in values {} }
        consumer.cancel()
        _ = try? await consumer.value
        await fulfillment(of: [cancelled], timeout: 1)
    }

    private func makeRuntime(provider: any AgentSessionProviding = DesignSessionProvider(),
        backend: DesignBackend = DesignBackend()) throws -> AgentRuntime {
        try AgentRuntime(configuration: .init(sessionProvider: provider, backend: backend,
            approvalPresenter: AutoApprovalPresenter(), stateStore: InMemoryRuntimeStateStore(),
            maximumBufferedEvents: 1, turnLimits: .init(maximumDuration: 3)))
    }
}

actor DesignSessionProvider: AgentSessionManaging {
    var value: ChatGPTSession? = demoSession()
    var actions: [String] = []
    func currentSession() -> ChatGPTSession? { value }
    func signIn() -> ChatGPTSession { actions.append("signIn"); value = demoSession(); return value! }
    func useSession(_ session: ChatGPTSession) -> ChatGPTSession { actions.append("useSession"); value = session; return session }
    func signOut() { actions.append("signOut"); value = nil }
    func recoverUnauthorizedSession(previousAccessToken: String?) -> ChatGPTSession {
        actions.append("recover")
        return demoSession()
    }
}

struct DesignReadOnlyProvider: AgentSessionProviding {
    func currentSession() async -> ChatGPTSession? { demoSession() }
}

struct DesignBackend: AgentBackend {
    var readiness: @Sendable () async throws -> Void = {}
    func createThread(session: ChatGPTSession) async throws -> AgentThread { .init(id: UUID().uuidString) }
    func resumeThread(id: String, session: ChatGPTSession) async throws -> AgentThread { .init(id: id) }
    func beginTurn(thread: AgentThread, history: [AgentMessage], message: Request, instructions: String,
        responseFormat: AgentStructuredOutputFormat?, streamedStructuredOutput: AgentStreamedStructuredOutputRequest?,
        tools: [ToolDefinition], session: ChatGPTSession) async throws -> AgentTurnStream {
        let turn = AgentTurn(id: UUID().uuidString, threadID: thread.id)
        return AgentTurnStream(events: AsyncThrowingStream { continuation in
            continuation.yield(.turnStarted(turn))
            continuation.yield(.assistantMessageCompleted(.init(threadID: thread.id, role: .assistant, text: "Done")))
            if streamedStructuredOutput != nil || responseFormat != nil {
                continuation.yield(.structuredOutputCommitted(.object(["value": .string("Done")])))
            }
            continuation.yield(.turnCompleted(.init(threadID: thread.id, turnID: turn.id)))
            continuation.finish()
        }, steer: nil, waitUntilReady: readiness)
    }
}

private struct DesignOutput: AgentStructuredOutput {
    let value: String
    static let responseFormat = AgentStructuredOutputFormat(name: "value", schema: .object(properties: ["value": .string()]))
}
