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
    public private(set) var runningTools: [String: String] = [:]
    public private(set) var peakConcurrentTools = 0
    public private(set) var reasoningSummary = ""

    public let approvalInbox: ApprovalInbox?
    public let deviceCodeCoordinator: DeviceCodePromptCoordinator?

    private let runtime: AgentRuntime
    private var activeThreadID: String?
    private var selectionGeneration = UUID()
    private var accountGeneration = UUID()
    private var sendingThreadIDs: Set<String> = []
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
        let selection = beginSelection(id: nil)
        let account = accountGeneration
        do {
            _ = try await runtime.restore()
            let restoredThreads = try await loadThreadMetadata()
            let restoredSession = await runtime.currentSession()
            let activeThreads = await runtime.activeThreads()
            guard selectionGeneration == selection, accountGeneration == account else { return }
            threads = restoredThreads
            session = restoredSession
            if let selectedThread = activeThreads.first {
                activeThreadID = selectedThread.id
                await refreshMessages(in: selectedThread.id, account: account)
            }
        } catch {
            if selectionGeneration == selection, accountGeneration == account { lastError = error.localizedDescription }
        }
    }

    public func signIn() async {
        accountGeneration = UUID()
        let account = accountGeneration
        do {
            let signedIn = try await runtime.signIn()
            let metadata = try await loadThreadMetadata()
            guard accountGeneration == account else { return }
            session = signedIn
            threads = metadata
        } catch {
            if accountGeneration == account { lastError = error.localizedDescription }
        }
    }

    public func signOut() async {
        accountGeneration = UUID()
        let account = accountGeneration
        _ = beginSelection(id: nil)
        session = nil
        rateLimits = []
        threads = []
        do {
            try await runtime.signOut()
        } catch {
            if accountGeneration == account { lastError = error.localizedDescription }
        }
    }

    public func createThread(title: String? = nil) async {
        let selection = beginSelection(id: nil)
        let account = accountGeneration
        do {
            let thread = try await runtime.createThread(title: title)
            let metadata = try await loadThreadMetadata()
            guard selectionGeneration == selection, accountGeneration == account else { return }
            threads = metadata
            activeThreadID = thread.id
            await refreshMessages(in: thread.id, account: account)
        } catch {
            if selectionGeneration == selection, accountGeneration == account { lastError = error.localizedDescription }
        }
    }

    public func activateThread(id: String) async {
        let selection = beginSelection(id: id)
        let account = accountGeneration
        do {
            let activeThreads = await runtime.activeThreads()
            guard selectionGeneration == selection, accountGeneration == account else { return }
            if !activeThreads.contains(where: { $0.id == id }) {
                _ = try await runtime.resumeThread(id: id)
            }
            let metadata = try await loadThreadMetadata()
            guard selectionGeneration == selection, accountGeneration == account else { return }
            threads = metadata
            await refreshMessages(in: id, account: account)
        } catch {
            if selectionGeneration == selection, accountGeneration == account { lastError = error.localizedDescription }
        }
    }

    public func send(_ text: String) async {
        await send(Request(text: text))
    }

    /// Sends image attachments, persona overrides, and other request options through the UI store.
    public func send(_ request: Request) async {
        guard !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !request.images.isEmpty else {
            return
        }

        if activeThreadID == nil {
            await createThread()
        }

        guard let activeThreadID else {
            lastError = "No active thread is available."
            return
        }
        guard sendingThreadIDs.insert(activeThreadID).inserted else { return }
        defer { sendingThreadIDs.remove(activeThreadID) }
        let account = accountGeneration

        streamingText = ""
        latestProgress = nil
        runningTools = [:]
        peakConcurrentTools = 0
        reasoningSummary = ""
        defer {
            if self.activeThreadID == activeThreadID, accountGeneration == account { runningTools = [:] }
        }

        do {
            let stream = try await runtime.stream(
                request,
                in: activeThreadID
            )
            await refreshMessages(in: activeThreadID, account: account)
            try await consume(stream, in: activeThreadID, account: account)
        } catch is CancellationError {
            if self.activeThreadID == activeThreadID, accountGeneration == account { streamingText = "" }
        } catch {
            if self.activeThreadID == activeThreadID, accountGeneration == account { lastError = error.localizedDescription }
        }
    }

    public func steer(_ text: String) async {
        let selection = selectionGeneration
        let account = accountGeneration
        guard let activeThreadID, let turnID = await runtime.activeTurnID(in: activeThreadID),
              selectionGeneration == selection, accountGeneration == account else { return }
        do {
            try await runtime.steer(text, in: activeThreadID, expectedTurnID: turnID)
        } catch {
            if selectionGeneration == selection, accountGeneration == account { lastError = error.localizedDescription }
        }
    }

    public func interrupt() async {
        guard let activeThreadID else { return }
        let selection = selectionGeneration
        let account = accountGeneration
        do { try await runtime.interrupt(in: activeThreadID) }
        catch {
            if selectionGeneration == selection, accountGeneration == account { lastError = error.localizedDescription }
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

    private func consume(
        _ stream: AsyncThrowingStream<AgentEvent, Error>,
        in threadID: String,
        account: UUID
    ) async throws {
        for try await event in stream {
            guard accountGeneration == account else { continue }
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
                if activeThreadID == threadID {
                    latestProgress = progress
                    if case let .reasoningSummaryDelta(_, _, delta) = progress.content {
                        reasoningSummary = String((reasoningSummary + delta).suffix(8_000))
                    }
                }
            case let .rateLimitsUpdated(snapshots):
                for snapshot in snapshots {
                    rateLimits.removeAll { $0.limitID == snapshot.limitID }
                    rateLimits.append(snapshot)
                }
            case .turnInterrupted:
                if activeThreadID == threadID {
                    latestProgress = nil
                    streamingText = ""
                }
                await refreshMessages(in: threadID, account: account)
                try await refreshThreadMetadata(account: account)
            case .turnStarted,
                 .approvalRequested,
                 .approvalResolved:
                break
            case let .toolCallStarted(invocation):
                if activeThreadID == threadID {
                    runningTools[invocation.id] = invocation.toolName
                    peakConcurrentTools = max(peakConcurrentTools, runningTools.count)
                }
            case let .toolCallFinished(result):
                if activeThreadID == threadID { runningTools[result.invocationID] = nil }

            case let .assistantMessageDelta(_, _, delta):
                if activeThreadID == threadID { streamingText.append(delta) }

            case let .messageCommitted(message):
                guard activeThreadID == threadID else { continue }
                if let index = messages.firstIndex(where: { $0.id == message.id }) {
                    messages[index] = message
                } else {
                    messages.append(message)
                }
                if message.role == .assistant {
                    streamingText = ""
                }

            case .turnCompleted:
                if activeThreadID == threadID {
                    latestProgress = nil
                    streamingText = ""
                }
                await refreshMessages(in: threadID, account: account)
                try await refreshThreadMetadata(account: account)

            case let .turnFailed(error):
                if activeThreadID == threadID { lastError = error.message }
            }
        }
    }

    private func beginSelection(id: String?) -> UUID {
        selectionGeneration = UUID()
        activeThreadID = id
        messages = []
        streamingText = ""
        latestProgress = nil
        runningTools = [:]
        peakConcurrentTools = 0
        reasoningSummary = ""
        return selectionGeneration
    }

    private func refreshMessages(in threadID: String, account: UUID) async {
        guard activeThreadID == threadID, accountGeneration == account else { return }
        let selection = selectionGeneration
        let snapshot = await runtime.messages(for: threadID)
        guard activeThreadID == threadID, selectionGeneration == selection, accountGeneration == account else { return }
        messages = snapshot
    }

    private func refreshThreadMetadata(account: UUID) async throws {
        let metadata = try await loadThreadMetadata()
        if accountGeneration == account { threads = metadata }
    }
}
