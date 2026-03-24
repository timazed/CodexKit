import CodexKit
import Foundation

@MainActor
extension AgentDemoViewModel {
    func sendComposerText() async {
        let outgoingText = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        let outgoingImages = pendingComposerImages

        guard !outgoingText.isEmpty || !outgoingImages.isEmpty else {
            return
        }

        composerText = ""
        pendingComposerImages = []
        await sendMessageInternal(
            outgoingText,
            images: outgoingImages
        )
    }

    func queueComposerImage(
        data: Data,
        mimeType: String
    ) {
        pendingComposerImages.append(
            AgentImageAttachment(
                mimeType: mimeType,
                data: data
            )
        )
    }

    func removePendingComposerImage(id: String) {
        pendingComposerImages.removeAll { $0.id == id }
    }

    func reportError(_ message: String) {
        developerErrorLog(message)
        lastError = message
    }

    func reportError(_ error: Error) {
        guard !diagnostics.isCancellationError(error) else {
            developerLog("Ignoring CancellationError from async UI task.")
            return
        }
        developerErrorLog(error.localizedDescription)
        lastError = error.localizedDescription
    }

    func approvePendingRequest() {
        approvalInbox.approveCurrent()
    }

    func denyPendingRequest() {
        approvalInbox.denyCurrent()
    }

    func dismissError() {
        lastError = nil
    }

    func developerLog(_ message: String) {
        guard developerLoggingEnabled else {
            return
        }
        diagnostics.log(message)
    }

    func developerErrorLog(_ message: String) {
        guard developerLoggingEnabled else {
            return
        }
        diagnostics.error(message)
    }

    func setMessages(_ incoming: [AgentMessage]) {
        messages = deduplicatedMessages(incoming)
    }

    func upsertMessage(_ message: AgentMessage) {
        if let existingIndex = messages.firstIndex(where: { $0.id == message.id }) {
            messages[existingIndex] = message
            return
        }
        messages.append(message)
    }

    private func deduplicatedMessages(_ incoming: [AgentMessage]) -> [AgentMessage] {
        var seen = Set<String>()
        var reversedUnique: [AgentMessage] = []
        reversedUnique.reserveCapacity(incoming.count)

        for message in incoming.reversed() {
            guard seen.insert(message.id).inserted else {
                continue
            }
            reversedUnique.append(message)
        }

        return reversedUnique.reversed()
    }
}
