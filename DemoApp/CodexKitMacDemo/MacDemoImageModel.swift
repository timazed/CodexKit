import AppKit
import CodexKit
import UniformTypeIdentifiers

@MainActor
extension ImageGenerationDemoModel {
    func chooseReferences() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .webP]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        importReferences(panel.urls)
    }

    func save(_ generated: AgentGeneratedImage) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "generated-image.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try generated.image.data.write(to: url, options: .atomic) }
        catch { reportImportError(error) }
    }
}
