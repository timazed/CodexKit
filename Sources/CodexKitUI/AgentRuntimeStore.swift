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
            let activeThreads = await runtime.threads()
            if let firstThread = activeThreads.first {
                activeThreadID = firstThread.id
                messages = await runtime.messages(for: firstThread.id)
            } else {
                activeThreadID = nil
                messages = []
            }
            session = await runtime.currentSession()
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
            let activeThreads = await runtime.threads()
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

        do {
            let stream = try await runtime.stream(
                Request(text: text),
                in: activeThreadID
            )
            messages = await runtime.messages(for: activeThreadID)

            for try await event in stream {
                switch event {
                case let .threadStarted(thread):
                    threads = [thread] + threads.filter { $0.id != thread.id }

                case let .threadStatusChanged(threadID, status):
                    threads = threads.map { thread in
                        guard thread.id == threadID else {
                            return thread
                        }

                        var updated = thread
                        updated.status = status
                        updated.updatedAt = Date()
                        return updated
                    }

                case .turnStarted:
                    break

                case let .assistantMessageDelta(_, _, delta):
                    streamingText.append(delta)

                case let .messageCommitted(message):
                    messages.append(message)
                    if message.role == .assistant {
                        streamingText = ""
                    }

                case .approvalRequested:
                    break

                case .approvalResolved:
                    break

                case .toolCallStarted:
                    break

                case .toolCallFinished:
                    break

                case .turnCompleted:
                    messages = await runtime.messages(for: activeThreadID)
                    threads = try await loadThreadMetadata()

                case let .turnFailed(error):
                    lastError = error.message
                }
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func dismissError() {
        lastError = nil
    }

    private func loadThreadMetadata() async throws -> [AgentThread] {
        try await runtime.execute(
            ThreadMetadataQuery(limit: restoredThreadLimit)
        )
    }
}
