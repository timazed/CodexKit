import CodexKit
import SwiftUI
import UniformTypeIdentifiers

struct ImageGenerationDemoView: View {
    @State private var images: ImageGenerationDemoModel
    @State private var importing = false
    @State private var exporting = false
    @State private var exportDocument = ImageExportDocument(data: Data())
    @State private var exportType = UTType.png

    init(session: @escaping @MainActor () async throws -> ChatGPTSession) {
        _images = State(initialValue: ImageGenerationDemoModel(session: session))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Create an image from a prompt, or edit reference photos.")
                controls.disabled(images.isBusy)
                HStack {
                    Button(images.action == .edit ? "Edit Image" : "Generate Image") { images.start() }
                        .buttonStyle(.borderedProminent).disabled(!images.canRun)
                    if images.isBusy {
                        TimelineView(.periodic(from: .now, by: 0.5)) { context in
                            if let percent = images.estimatedPercentage(at: context.date) {
                                Text("Estimated \(percent)%").monospacedDigit()
                                    .accessibilityLabel("Estimated image progress: \(percent) percent")
                            } else {
                                ProgressView().controlSize(.small)
                            }
                        }
                        Button("Cancel") { images.cancel() }
                    } else if images.status == .cancelled {
                        Text("Cancelled").foregroundStyle(.secondary)
                    }
                }
                if let error = images.error {
                    Text(error).foregroundStyle(.orange)
                    if let failure = images.failure {
                        DisclosureGroup("Error details") {
                            Text("Code: \(failure.code)").font(.caption.monospaced())
                            if let http = failure.http {
                                Text("HTTP status: \(http.statusCode)")
                                if let code = http.providerCode { Text("Provider code: \(code)") }
                                if let type = http.providerType { Text("Provider type: \(type)") }
                            }
                            if let details = failure.imageGeneration { ImageGenerationDiagnosticsView(details: details) }
                        }.textSelection(.enabled)
                    }
                }
                ForEach(images.results) { result in
                    GroupBox(images.showingAnimationSample ? "Local animation sample" : "Generated image") {
                        VStack(alignment: .leading, spacing: 12) {
                            GeneratedImagePreview(image: result.image)
                            Text("\(result.image.mimeType == .gif ? "GIF" : "PNG") · \(result.pixelSize?.description ?? "Dimensions unavailable")").font(.caption)
                            Button("Save Image…") {
                                exportDocument = ImageExportDocument(data: result.image.data)
                                exportType = result.demoExportType
                                exporting = true
                            }
                            if let details = result.diagnostics {
                                DisclosureGroup("Image details") { ImageGenerationDiagnosticsView(details: details) }
                            }
                        }
                    }
                }
            }.padding()
        }
        .navigationTitle("Images")
        .fileImporter(isPresented: $importing, allowedContentTypes: [.png, .jpeg, .webP], allowsMultipleSelection: true) { result in
            switch result {
            case let .success(urls): images.importReferences(urls)
            case let .failure(error): images.reportImportError(error)
            }
        }
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: exportType, defaultFilename: "generated-image") { result in
            if case let .failure(error) = result { images.reportImportError(error) }
        }
        .onDisappear { images.cancel() }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Action", selection: $images.action) {
                Text("Generate").tag(AgentImageGenerationAction.generate)
                Text("Edit").tag(AgentImageGenerationAction.edit)
            }.pickerStyle(.segmented)
            Toggle("Transparent background", isOn: $images.transparentBackground)
            ImageGenerationOutputControls(images: images)
            TextField("Describe the image or edit", text: $images.prompt, axis: .vertical)
                .lineLimit(3...8).textFieldStyle(.roundedBorder)
            if images.action == .edit {
                Button("Choose Reference Images…") { importing = true }
                Text("Up to five PNG, JPEG, or WebP images").font(.caption).foregroundStyle(.secondary)
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(images.references) { reference in
                            if let preview = Image(platformData: reference.data) {
                                preview.resizable().scaledToFit().frame(width: 80, height: 80)
                            }
                        }
                    }
                }
                if !images.references.isEmpty { Button("Remove References") { images.references = [] } }
            }
        }
    }
}

private struct ImageExportDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.png, .gif]
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
