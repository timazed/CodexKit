import AppKit
import CodexKit
import UniformTypeIdentifiers

extension MacDemoModel {
    func attachImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        do {
            guard pendingImages.count + panel.urls.count <= 4 else {
                throw MacDemoFeatureError("Attach up to four images per message.")
            }
            let attachments = try panel.urls.map { url in
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 10 * 1_024 * 1_024 else { throw MacDemoFeatureError("Choose images smaller than 10 MB each.") }
                let data = try Data(contentsOf: url)
                guard NSImage(data: data) != nil else { throw MacDemoFeatureError("The selected file is not a readable image.") }
                return AgentImageAttachment(mimeType: url.pathExtension.lowercased() == "png" ? .png : .jpeg, data: data)
            }
            pendingImages += attachments
        } catch { errorMessage = error.localizedDescription }
    }

    func addToTurn() async {
        guard isSending, let runtime, let thread = chat?.activeThread else { return }
        let text = composer
        let images = pendingImages
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty else { return }
        do {
            guard let turnID = await runtime.activeTurnID(in: thread.id) else { return }
            try await runtime.steer(text, images: images, in: thread.id, expectedTurnID: turnID)
            if composer == text { composer = "" }
            let sent = Set(images.map(\.id))
            pendingImages.removeAll { sent.contains($0.id) }
        } catch { errorMessage = error.localizedDescription }
    }

    func runFeature(_ action: MacDemoAction) {
        guard isConnected, !isWorking, let features else { return }
        features.configuration = .init(model: modelID, reasoningEffort: reasoningEffort)
        features.run(action) { [weak self] in
            guard let self, self.features === features else { return }
            self.useMemory = features.chat.activeThread?.memoryContext != nil
            await self.checkSession()
        }
    }
}
