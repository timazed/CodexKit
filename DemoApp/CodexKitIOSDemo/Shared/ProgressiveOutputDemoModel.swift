import CodexKit
import Foundation
import Observation

enum ProgressiveOutputDemoMode: String, CaseIterable, Identifiable {
    case text = "Text", records = "JSON Lines", xml = "XML", json = "Native JSON"
    var id: String {
        switch self {
        case .text: "text"
        case .records: "records"
        case .xml: "xml"
        case .json: "json"
        }
    }

    var requestID: String { "demo.streaming.\(id)" }

    var explanation: String {
        switch self {
        case .text: "Final-answer text arrives in deltas, then commits as one saved result."
        case .records:
            "Each complete JSON line becomes a typed card. The collection commits only after all three records validate."
        case .xml:
            "XML text streams into cards with id and priority attributes. Closing an element is provisional; XSD validates the entire document before commit."
        case .json:
            "Raw JSON deltas are a preview, not a decodable model. The typed card appears after final validation and persistence."
        }
    }

    var request: Request {
        let prompt: String
        switch self {
        case .text: prompt = "Give three short software testing tips in plain text."
        case .records:
            prompt = "Give three software testing tips with id 1, 2, 3, a short title, and a paragraph of text."
        case .xml:
            prompt =
                "Give three software testing tips, with id 1, 2, 3 and low/high priority. Write a short paragraph in each tip."
        case .json: prompt = "Give one software testing tip with id 1, a short title, and a paragraph of text."
        }
        return Request(text: prompt + " Finish any tool work before the final answer.").correlated(with: requestID)
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
    static let records = AgentRecordResponseFormat(
        name: "testing_tips_records", record: ProgressiveDemoRecord.self,
        schema: ProgressiveDemoRecord.schema, minimumRecords: 3, maximumRecords: 3)
    static let json = AgentJSONResponseFormat<ProgressiveDemoRecord>(
        name: "testing_tip_json", schema: ProgressiveDemoRecord.schema)
    static let xml = AgentXMLResponseFormat(
        name: "testing_tips_xml",
        schema: .element(
            "response",
            children: .sequence([
                .element(
                    "tip", text: .string,
                    attributes: [
                        "id": .required(.integer),
                        "priority": .required(.string(enum: ["low", "high"])),
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
        id = String(index)
        title = record.title
        attributes = "id=\(record.id)"
        text = record.text
        isClosed = true
    }

    init(info: AgentXMLElementInfo, text: String = "", isClosed: Bool = false) {
        id = String(info.id)
        title = info.indexedPath
        attributes = info.attributes.map { "\($0.key.expandedName)=\($0.value)" }.sorted().joined(separator: " · ")
        self.text = text
        self.isClosed = isClosed
    }
}

/// Host-owned operation state and result presentation shared by both demos.
@MainActor
@Observable
final class ProgressiveOutputDemoModel {
    enum Operation { case idle, running, reloading }
    enum Origin { case generated, restored }
    enum ResultState {
        case empty
        case provisional
        case committed(Origin)
        case cancelled
        case failed(String)
    }

    private(set) var operation: Operation = .idle
    private(set) var result: ResultState = .empty
    private(set) var mode: ProgressiveOutputDemoMode = .records
    private(set) var units: [ProgressiveDemoUnit] = []
    private(set) var rawText = ""
    private(set) var context: AgentOutputContext?
    private(set) var threadID: String?
    private(set) var previewEvents = 0
    private(set) var operationError: String?
    @ObservationIgnored private var task: Task<Void, Never>?

    var isBusy: Bool { operation != .idle }
    var isRunning: Bool { operation == .running }
    var isReloading: Bool { operation == .reloading }
    var isCommitted: Bool {
        if case .committed = result { return true }
        return false
    }
    var restored: Bool {
        if case .committed(.restored) = result { return true }
        return false
    }
    var error: String? {
        if case let .failed(message) = result { return message }
        return operationError
    }
    var status: String {
        switch result {
        case .empty: "Choose a format, then run a new turn."
        case .provisional: "Provisional — not yet validated or saved."
        case .committed(.generated): "Committed — final validation and persistence succeeded."
        case .committed(.restored): "Restored — loaded the saved output without a model request."
        case .cancelled: "Cancelled — any previews below are uncommitted."
        case .failed: "Failed — any previews below are uncommitted."
        }
    }

    func start(
        _ mode: ProgressiveOutputDemoMode,
        runtime: AgentRuntime,
        configuration: AgentThreadConfiguration,
        didCreateThread: @escaping @MainActor (String) async -> Void = { _ in }
    ) {
        guard !isBusy else { return }
        resetPresentation(mode: mode)
        result = .provisional
        operation = .running
        task = Task {
            defer { finishOperation() }
            do {
                try Task.checkCancellation()
                let thread = try await runtime.createThread(
                    title: "Streaming \(mode.rawValue)",
                    configuration: configuration
                )
                threadID = thread.id
                try Task.checkCancellation()
                await didCreateThread(thread.id)
                try Task.checkCancellation()
                try await stream(mode, runtime: runtime, threadID: thread.id)
            } catch {
                // Persistence may win a cancellation race. Never discard a known commit.
                if isCommitted {
                    operationError = error.localizedDescription
                } else if error is CancellationError || Task.isCancelled {
                    result = .cancelled
                } else {
                    result = .failed(error.localizedDescription)
                }
            }
        }
    }

    func cancel() {
        task?.cancel()
    }

    func waitUntilFinished() async {
        await task?.value
    }

    func reload(runtime: AgentRuntime) {
        guard let threadID, isCommitted else { return }
        restore(mode, threadID: threadID, runtime: runtime)
    }

    /// Also works on a fresh model, using a saved thread/format selection.
    func restore(_ mode: ProgressiveOutputDemoMode, threadID: String, runtime: AgentRuntime) {
        guard !isBusy else { return }
        operation = .reloading
        operationError = nil
        task = Task {
            defer { finishOperation() }
            do {
                // Read both the typed value and its persisted source/identity. Do not
                // rely on raw text retained by an earlier streaming presentation.
                guard
                    let representation = try await runtime.fetchLatestStructuredOutputMetadata(id: threadID)?
                        .outputRepresentation
                else {
                    throw AgentOutputError.invalidOutput("No saved output was found.")
                }
                try Task.checkCancellation()
                switch mode {
                case .text:
                    rawText = try await stored(ProgressiveDemoFormats.text, runtime: runtime, threadID: threadID)
                    units = []
                case .records:
                    render(
                        try await stored(ProgressiveDemoFormats.records, runtime: runtime, threadID: threadID).records)
                    rawText = ""
                case .xml:
                    render(try await stored(ProgressiveDemoFormats.xml, runtime: runtime, threadID: threadID))
                case .json:
                    render([try await stored(ProgressiveDemoFormats.json, runtime: runtime, threadID: threadID)])
                    rawText = representation.rawText
                }
                self.mode = mode
                self.threadID = threadID
                context = representation.context
                result = .committed(.restored)
            } catch {
                operationError = "Could not reload saved output: \(error.localizedDescription)"
            }
        }
    }

    private func resetPresentation(mode: ProgressiveOutputDemoMode) {
        self.mode = mode
        units = []
        rawText = ""
        context = nil
        threadID = nil
        previewEvents = 0
        operationError = nil
    }

    private func finishOperation() {
        operation = .idle
        task = nil
    }

    private func stream(_ mode: ProgressiveOutputDemoMode, runtime: AgentRuntime, threadID: String) async throws {
        switch mode {
        case .text:
            try await consume(ProgressiveDemoFormats.text, runtime: runtime, threadID: threadID) {
                if case let .textDelta(text) = $0 { self.rawText += text }
            } render: {
                self.rawText = $0
            }
        case .records:
            try await consume(ProgressiveDemoFormats.records, runtime: runtime, threadID: threadID) {
                if case let .recordCompleted(index, record) = $0 {
                    self.units.append(.init(record: record, index: index))
                }
            } render: {
                self.render($0.records)
            }
        case .xml:
            try await consume(ProgressiveDemoFormats.xml, runtime: runtime, threadID: threadID) {
                self.previewXML($0)
            } render: {
                self.render($0)
            }
        case .json:
            try await consume(ProgressiveDemoFormats.json, runtime: runtime, threadID: threadID) {
                if case let .rawJSONDelta(text) = $0 { self.rawText += text }
            } render: {
                self.render([$0])
            }
        }
    }

    private func stored<F: AgentOutputFormat>(_ format: F, runtime: AgentRuntime, threadID: String) async throws
        -> F.Output
    {
        guard let value = try await runtime.fetchLatestOutput(in: threadID, output: format) else {
            throw AgentOutputError.invalidOutput("No saved output was found for this format.")
        }
        return value
    }

    private func consume<F: AgentOutputFormat>(
        _ format: F, runtime: AgentRuntime, threadID: String,
        preview: (F.Event) -> Void, render: (F.Output) -> Void
    ) async throws {
        let execution = try await runtime.start(mode.request, in: threadID, output: format)
        try await withTaskCancellationHandler {
            for try await event in execution.events {
                switch event {
                case let .format(context, event):
                    self.context = context
                    previewEvents += 1
                    preview(event)
                case let .validationFailed(_, failure):
                    operationError = failure.message
                case let .outputCommitted(context, output):
                    self.context = context
                    render(output)
                    result = .committed(.generated)
                case .lifecycle:
                    break
                }
            }
            guard isCommitted else {
                try Task.checkCancellation()
                throw AgentOutputError.invalidOutput("The stream ended without a committed output.")
            }
        } onCancel: {
            execution.cancel()
        }
    }

    private func previewXML(_ event: AgentXMLOutputEvent) {
        switch event {
        case let .elementStarted(info) where info.path.count == 2:
            units.append(.init(info: info))
        case let .textDelta(id, text):
            if let index = units.firstIndex(where: { $0.id == String(id) }) {
                units[index].text += text
            }
        case let .elementCompleted(element):
            if let index = units.firstIndex(where: { $0.id == String(element.id) }) {
                units[index] = .init(info: element.info, text: element.text, isClosed: true)
            }
        default:
            break
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
