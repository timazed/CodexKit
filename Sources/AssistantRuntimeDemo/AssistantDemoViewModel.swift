import AssistantRuntimeKit
import Foundation
import Observation

@MainActor
@Observable
public final class AssistantDemoViewModel: @unchecked Sendable {
    public private(set) var session: ChatGPTSession?
    public private(set) var threads: [AssistantThread] = []
    public private(set) var messages: [AssistantMessage] = []
    public private(set) var streamingAssistantText = ""
    public private(set) var lastError: String?
    public var composerText = ""

    public let approvalInbox: ApprovalInbox

    private let runtime: AgentRuntime
    private var activeThreadID: String?

    public init(runtime: AgentRuntime, approvalInbox: ApprovalInbox) {
        self.runtime = runtime
        self.approvalInbox = approvalInbox
    }

    public var activeThread: AssistantThread? {
        guard let activeThreadID else {
            return nil
        }
        return threads.first { $0.id == activeThreadID }
    }

    public func restore() async {
        do {
            _ = try await runtime.restore()
            threads = await runtime.threads()
            if let firstThread = threads.first {
                activeThreadID = firstThread.id
                messages = await runtime.messages(for: firstThread.id)
            }
            session = await runtime.sessionManager.currentSession()
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func signIn() async {
        do {
            session = try await runtime.signIn()
            threads = await runtime.threads()
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func registerDemoTool() async {
        let definition = ToolDefinition(
            name: "demo.lookupProfile",
            description: "Return a deterministic demo profile payload.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "message": .object(["type": .string("string")]),
                ]),
            ]),
            approvalPolicy: .requiresApproval,
            approvalMessage: "Allow the demo app to run the registered profile lookup tool?"
        )

        await runtime.replaceTool(definition, executor: AnyToolExecutor { invocation, _ in
            let requestedMessage: String
            if case let .object(arguments) = invocation.arguments,
               let message = arguments["message"]?.stringValue {
                requestedMessage = message
            } else {
                requestedMessage = "No message"
            }

            return .success(
                invocation: invocation,
                text: "profile[name=Taylor, source=demo, input=\(requestedMessage)]"
            )
        })
    }

    public func createThread() async {
        do {
            let thread = try await runtime.createThread()
            threads = await runtime.threads()
            activeThreadID = thread.id
            messages = await runtime.messages(for: thread.id)
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func activateThread(id: String) async {
        activeThreadID = id
        messages = await runtime.messages(for: id)
        streamingAssistantText = ""
    }

    public func sendComposerText() async {
        guard !composerText.isEmpty else {
            return
        }

        if activeThreadID == nil {
            await createThread()
        }

        guard let activeThreadID else {
            lastError = "No active thread is available."
            return
        }

        let outgoingText = composerText
        composerText = ""
        streamingAssistantText = ""

        do {
            let stream = try await runtime.sendMessage(
                UserMessageRequest(text: outgoingText),
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
                    streamingAssistantText.append(delta)

                case let .messageCommitted(message):
                    messages.append(message)
                    if message.role == .assistant {
                        streamingAssistantText = ""
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
                    threads = await runtime.threads()

                case let .turnFailed(error):
                    lastError = error.message
                }
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func approvePendingRequest() {
        approvalInbox.approveCurrent()
    }

    public func denyPendingRequest() {
        approvalInbox.denyCurrent()
    }

    public func dismissError() {
        lastError = nil
    }
}
