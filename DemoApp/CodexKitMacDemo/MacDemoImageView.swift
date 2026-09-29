import AppKit
import CodexKit
import SwiftUI

struct MacDemoImageView: View {
    @Bindable var model: MacDemoModel
    @Bindable var images: ImageGenerationDemoModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Image generation").font(.title2.bold())
            Text("Create an image from a prompt, or edit a reference photo.").foregroundStyle(.secondary)
            controls.disabled(model.isWorking)
            HStack {
                Button(images.action == .edit ? "Edit Image" : "Generate Image") { model.runImageGeneration() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isWorking || model.isOfflineDemo || !images.canRun)
                if images.isBusy {
                    ProgressView().controlSize(.small)
                    Text("Generating…").foregroundStyle(.secondary)
                    Button("Cancel") { images.cancel() }
                } else if images.status == .cancelled {
                    Text("Cancelled").foregroundStyle(.secondary)
                } else if images.status == .completed {
                    Label("Completed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
            if let error = images.error {
                Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.orange).textSelection(.enabled)
                if let failure = images.failure {
                    DisclosureGroup("Error details") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Code: \(failure.code)")
                            if let http = failure.http {
                                Text("HTTP status: \(http.statusCode)")
                                if let code = http.providerCode { Text("Provider code: \(code)") }
                                if let type = http.providerType { Text("Provider type: \(type)") }
                                if let id = http.requestID { Text("Request ID: \(id)") }
                            }
                            if let details = failure.imageGeneration {
                                ImageGenerationDiagnosticsView(details: details)
                            }
                            if let id = failure.interruption?.clientRequestID { Text("Client request ID: \(id)") }
                            if let id = failure.interruption?.responseID { Text("Response ID: \(id)") }
                        }.font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
            }
            ForEach(images.results) { result in
                GroupBox("Generated image") {
                    VStack(spacing: 12) {
                        if let preview = NSImage(data: result.image.data) {
                            Image(nsImage: preview).resizable().scaledToFit().frame(maxHeight: 480)
                        }
                        HStack {
                            Text(result.image.mimeType.rawValue).font(.caption).foregroundStyle(.secondary)
                            if let actualSize = result.pixelSize {
                                Text(actualSize.description).font(.caption).foregroundStyle(.secondary)
                            }
                            if let metadata = result.image.generationMetadata {
                                Text([metadata.quality.map { "Quality: \($0)" }].compactMap { $0 }
                                    .joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Save Image…") { images.save(result) }
                        }
                        if let details = result.diagnostics {
                            DisclosureGroup("Image details") { ImageGenerationDiagnosticsView(details: details) }
                        }
                    }.padding(8)
                }
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Action", selection: $images.action) {
                Text("Generate").tag(AgentImageGenerationAction.generate)
                Text("Edit").tag(AgentImageGenerationAction.edit)
            }
            Toggle("Transparent background", isOn: $images.transparentBackground)
            Text("PNG output. Quality and dimensions are chosen by the service.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Describe the image or edit", text: $images.prompt, axis: .vertical)
                .lineLimit(3...8).textFieldStyle(.roundedBorder)
            if images.action != .generate {
                HStack {
                    Button("Choose Reference Images…") { images.chooseReferences() }
                    if images.references.isEmpty {
                        Text("JPEG, PNG, or WebP").foregroundStyle(.secondary)
                    } else {
                        Button("Remove References") { images.references = [] }
                    }
                }
                HStack {
                    ForEach(images.references) { reference in
                        if let preview = NSImage(data: reference.data) {
                            Image(nsImage: preview).resizable().scaledToFit().frame(width: 100, height: 100)
                        }
                    }
                }
            }
        }
    }
}
