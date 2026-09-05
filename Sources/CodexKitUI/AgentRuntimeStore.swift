import CodexKit
import Foundation
import Observation

@MainActor
@Observable
public final class AgentRuntimeStore {
    public private(set) var session: ChatGPTSession?
    public private(set) var threads: [AgentThread] = []
    public private(set) var messages: [AgentMessage] = []
    public private(set) var streamingText = ""
    public private(set) var lastError: String?
    public private(set) var latestProgress: AgentTurnProgress?
    public private(set) var rateLimits: [AgentRateLimitSnapshot] = []

    public let approvalInbox: ApprovalInbox?
    public let deviceCodeCoordinator: DeviceCodePromptCoordinator?

    private let runtime: AgentRuntime
    private var activeThreadID: String?
    private let restoredThreadLimit = 50

    public init(
        runtime: AgentRuntime,
        approvalInbox: ApprovalInbox? = nil,
        deviceCodeCoordinator: DeviceCodePromptCoordinator? = nil
    ) {
        self.runtime = runtime
        self.approvalInbox = approvalInbox
        self.deviceCodeCoordinator = deviceCodeCoordinator
    }

    public var activeThread: AgentThread? {
        guard let activeThreadID else {
            return nil
        }

        return threads.first { $0.id == activeThreadID }
    }

    public func restore() async {
        do {
            _ = try await runtime.restore()
            threads = try await loadThreadMetadata()
            session = await runtime.currentSession()
            let activeThreads = await runtime.activeThreads()
            if let selectedThread = activeThreads.first {
                activeThreadID = selectedThread.id
                messages = await runtime.messages(for: selectedThread.id)
            } else {
                activeThreadID = nil
                messages = []
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func signIn() async {
        do {
            session = try await runtime.signIn()
            threads = try await loadThreadMetadata()
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func signOut() async {
        do {
            try await runtime.signOut()
            session = nil
            rateLimits = []
            latestProgress = nil
            threads = []
            messages = []
            streamingText = ""
            activeThreadID = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func createThread(title: String? = nil) async {
        do {
            let thread = try await runtime.createThread(title: title)
            threads = try await loadThreadMetadata()
            activeThreadID = thread.id
            messages = await runtime.messages(for: thread.id)
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func activateThread(id: String) async {
        do {
            let activeThreads = await runtime.activeThreads()
            if !activeThreads.contains(where: { $0.id == id }) {
                _ = try await runtime.resumeThread(id: id)
                threads = try await loadThreadMetadata()
            }
            activeThreadID = id
            messages = await runtime.messages(for: id)
            streamingText = ""
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func send(_ text: String) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        if activeThreadID == nil {
            await createThread()
        }

        guard let activeThreadID else {
            lastError = "No active thread is available."
            return
        }

        streamingText = ""
        latestProgress = nil

        do {
            let stream = try await runtime.stream(
                Request(text: text),
                in: activeThreadID
            )
            messages = await runtime.messages(for: activeThreadID)
            try await consume(stream, in: activeThreadID)
        } catch is CancellationError {
            streamingText = ""
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func steer(_ text: String) async {
        guard let activeThreadID, let turnID = await runtime.activeTurnID(in: activeThreadID) else { return }
        do {
            try await runtime.steer(text, in: activeThreadID, expectedTurnID: turnID)
        } catch { lastError = error.localizedDescription }
    }

    public func interrupt() async {
        guard let activeThreadID else { return }
        do { try await runtime.interrupt(in: activeThreadID) }
        catch { lastError = error.localizedDescription }
    }

    public func dismissError() {
        lastError = nil
    }

    private func loadThreadMetadata() async throws -> [AgentThread] {
        try await runtime.execute(
            ThreadMetadataQuery(limit: restoredThreadLimit)
        )
    }

    private func consume(
        _ stream: AsyncThrowingStream<AgentEvent, Error>,
        in activeThreadID: String
    ) async throws {
        for try await event in stream {
            switch event {
            case let .threadStarted(thread):
                threads = [thread] + threads.filter { $0.id != thread.id }

            case let .threadStatusChanged(threadID, status):
                threads = threads.map { thread in
                    guard thread.id == threadID else { return thread }
                    var updated = thread
                    updated.status = status
                    updated.updatedAt = Date()
                    return updated
                }

            case let .progress(progress):
                latestProgress = progress
            case let .rateLimitsUpdated(snapshots):
                for snapshot in snapshots {
                    rateLimits.removeAll { $0.limitID == snapshot.limitID }
                    rateLimits.append(snapshot)
                }
            case .turnInterrupted:
                latestProgress = nil
                streamingText = ""
                messages = await runtime.messages(for: activeThreadID)
                threads = try await loadThreadMetadata()
            case .turnStarted,
                 .approvalRequested,
                 .approvalResolved,
                 .toolCallStarted,
                 .toolCallFinished:
                break

            case let .assistantMessageDelta(_, _, delta):
                streamingText.append(delta)

            case let .messageCommitted(message):
                messages.append(message)
                if message.role == .assistant {
                    streamingText = ""
                }

            case .turnCompleted:
                latestProgress = nil
                messages = await runtime.messages(for: activeThreadID)
                threads = try await loadThreadMetadata()

            case let .turnFailed(error):
                lastError = error.message
            }
        }
    }
}
