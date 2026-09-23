import CodexKit
import Foundation
import Observation

enum ProgressiveOutputDemoMode: String, CaseIterable, Identifiable {
    case text = "Text", records = "JSON Lines", xml = "XML", json = "Native JSON"
    var id: String { rawValue }

    var explanation: String {
        switch self {
        case .text: "Final-answer text arrives in deltas, then commits as one saved result."
        case .records: "Each complete JSON line becomes a typed card. The collection commits only after all three records validate."
        case .xml: "XML text streams into cards with id and priority attributes. Closing an element is provisional; XSD validates the entire document before commit."
        case .json: "Raw JSON deltas are a preview, not a decodable model. The typed card appears after final validation and persistence."
        }
    }

    var request: Request {
        let prompt: String
        switch self {
        case .text: prompt = "Give three short software testing tips in plain text."
        case .records: prompt = "Give three software testing tips with id 1, 2, 3, a short title, and a paragraph of text."
        case .xml: prompt = "Give three software testing tips, with id 1, 2, 3 and low/high priority. Write a short paragraph in each tip."
        case .json: prompt = "Give one software testing tip with id 1, a short title, and a paragraph of text."
        }
        return Request(text: prompt + " Finish any tool work before the final answer.")
    }
}

struct ProgressiveDemoRecord: Codable, Sendable {
    let id: Int
    let title: String
    let text: String
    static let schema = JSONSchema.object(
        properties: ["id": .integer, "title": .string(), "text": .string()],
        required: ["id", "title", "text"], additionalProperties: false)
}

enum ProgressiveDemoFormats {
    static let text = AgentTextResponseFormat(name: "testing_tips_text")
    static let records = AgentRecordResponseFormat(name: "testing_tips_records", record: ProgressiveDemoRecord.self,
        schema: ProgressiveDemoRecord.schema, minimumRecords: 3, maximumRecords: 3)
    static let json = AgentJSONResponseFormat<ProgressiveDemoRecord>(name: "testing_tip_json", schema: ProgressiveDemoRecord.schema)
    static let xml = AgentXMLResponseFormat(name: "testing_tips_xml", schema: .element("response", children: .sequence([
        .element("tip", text: .string, attributes: [
            "id": .required(.integer),
            "priority": .required(.string(enum: ["low", "high"]))
        ], occurs: .range(min: 3, max: 3))
    ])), streaming: .init(identityAttribute: "id"))
}

struct ProgressiveDemoUnit: Identifiable, Equatable {
    let id: String
    let title: String
    let attributes: String
    var text: String
    var isClosed: Bool

    init(record: ProgressiveDemoRecord, index: Int) {
        id = String(index); title = record.title; attributes = "id=\(record.id)"
        text = record.text; isClosed = true
    }

    init(info: AgentXMLElementInfo, text: String = "", isClosed: Bool = false) {
        id = String(info.id); title = info.indexedPath
        attributes = info.attributes.map { "\($0.key.expandedName)=\($0.value)" }.sorted().joined(separator: " · ")
        self.text = text; self.isClosed = isClosed
    }
}

/// The UI and offline app checks use the same turn consumer and presentation state.
@MainActor
@Observable
final class ProgressiveOutputDemoModel {
    enum Phase { case idle, streaming, committed, cancelled, failed }
    private(set) var phase: Phase = .idle
    private(set) var mode: ProgressiveOutputDemoMode = .records
    private(set) var units: [ProgressiveDemoUnit] = []
    private(set) var rawText = ""
    private(set) var context: AgentOutputContext?
    private(set) var threadID: String?
    private(set) var previewEvents = 0
    private(set) var isRunning = false
    private(set) var isReloading = false
    private(set) var restored = false
    private(set) var error: String?

    var status: String {
        switch phase {
        case .idle: "Choose a format, then run a new turn."
        case .streaming: "Provisional — not yet validated or saved."
        case .committed: restored ? "Restored — loaded the saved output without a model request." : "Committed — final validation and persistence succeeded."
        case .cancelled: "Cancelled — any previews below are uncommitted."
        case .failed: "Failed — any previews below are uncommitted."
        }
    }

    func run(_ mode: ProgressiveOutputDemoMode, runtime: AgentRuntime, configuration: AgentThreadConfiguration) async {
        guard !isRunning, !isReloading else { return }
        self.mode = mode; phase = .streaming; isRunning = true; restored = false
        units = []; rawText = ""; context = nil; threadID = nil; previewEvents = 0; error = nil
        defer { isRunning = false }
        do {
            try Task.checkCancellation()
            let thread = try await runtime.createThread(title: "Streaming \(mode.rawValue)", configuration: configuration)
            threadID = thread.id
            try Task.checkCancellation()
            switch mode {
            case .text:
                try await consume(ProgressiveDemoFormats.text, runtime: runtime, threadID: thread.id) {
                    if case let .textDelta(text) = $0 { self.rawText += text }
                } render: { self.rawText = $0 }
            case .records:
                try await consume(ProgressiveDemoFormats.records, runtime: runtime, threadID: thread.id) {
                    if case let .recordCompleted(index, record) = $0 {
                        self.units.append(.init(record: record, index: index))
                    }
                } render: { self.render($0.records) }
            case .xml:
                try await consume(ProgressiveDemoFormats.xml, runtime: runtime, threadID: thread.id) {
                    self.previewXML($0)
                } render: { self.render($0) }
            case .json:
                try await consume(ProgressiveDemoFormats.json, runtime: runtime, threadID: thread.id) {
                    if case let .rawJSONDelta(text) = $0 { self.rawText += text }
                } render: { self.render([$0]) }
            }
        } catch {
            // A late cancellation must not relabel an already durable result as uncommitted.
            if phase != .committed {
                phase = error is CancellationError || Task.isCancelled ? .cancelled : .failed
            }
            if phase != .cancelled { self.error = error.localizedDescription }
        }
    }

    func reload(runtime: AgentRuntime) async {
        guard !isRunning, !isReloading, phase == .committed, let threadID else { return }
        isReloading = true; error = nil
        defer { isReloading = false }
        do {
            switch mode {
            case .text: rawText = try await stored(ProgressiveDemoFormats.text, runtime: runtime, threadID: threadID)
            case .records: render(try await stored(ProgressiveDemoFormats.records, runtime: runtime, threadID: threadID).records)
            case .xml: render(try await stored(ProgressiveDemoFormats.xml, runtime: runtime, threadID: threadID))
            case .json: render([try await stored(ProgressiveDemoFormats.json, runtime: runtime, threadID: threadID)])
            }
            restored = true
        } catch { self.error = "Could not reload saved output: \(error.localizedDescription)" }
    }

    private func stored<F: AgentOutputFormat>(_ format: F, runtime: AgentRuntime, threadID: String) async throws -> F.Decoder.Output {
        guard let value = try await runtime.fetchLatestOutput(in: threadID, output: format) else {
            throw AgentOutputError.invalidOutput("No saved output was found for this format.")
        }
        return value
    }

    private func consume<F: AgentOutputFormat>(
        _ format: F, runtime: AgentRuntime, threadID: String,
        preview: (F.Decoder.Event) -> Void, render: (F.Decoder.Output) -> Void
    ) async throws {
        let execution = try await runtime.start(mode.request, in: threadID, output: format)
        try await withTaskCancellationHandler {
            for try await event in execution.events {
                switch event {
                case let .format(context, event):
                    self.context = context; previewEvents += 1; preview(event)
                case let .validationFailed(_, failure): error = failure.message
                case let .outputCommitted(context, output):
                    self.context = context; render(output); phase = .committed
                case .lifecycle: break
                }
            }
            guard phase == .committed else {
                try Task.checkCancellation()
                throw AgentOutputError.invalidOutput("The stream ended without a committed output.")
            }
        } onCancel: { execution.cancel() }
    }

    private func previewXML(_ event: AgentXMLOutputEvent) {
        switch event {
        case let .elementStarted(info) where info.path.count == 2:
            units.append(.init(info: info))
        case let .textDelta(id, text):
            if let index = units.firstIndex(where: { $0.id == String(id) }) { units[index].text += text }
        case let .elementCompleted(element):
            if let index = units.firstIndex(where: { $0.id == String(element.id) }) {
                units[index] = .init(info: element.info, text: element.text, isClosed: true)
            }
        default: break
        }
    }

    private func render(_ records: [ProgressiveDemoRecord]) {
        units = records.enumerated().map { .init(record: $0.element, index: $0.offset) }
    }

    private func render(_ document: AgentXMLDocument) {
        rawText = document.rawXML
        units = document.root.children.map { .init(info: $0.info, text: $0.text, isClosed: true) }
    }
}
