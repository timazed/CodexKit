import CodexKit
import Foundation
import SwiftUI

struct ShippingReplyContext: Codable, Sendable {
    let orderRegion: String
    let promisedDeliveryWindow: String
    let eventDeadline: String
    let supportChannel: String
}

enum ShippingReplyMode: RequestMode {
    case inboxSupport

    var naturalLanguage: String {
        switch self {
        case .inboxSupport:
            return "Draft a concise in-app support reply that sounds calm, realistic, and action-oriented."
        }
    }
}

enum ShippingReplyRequirement: RequestRequirement {
    case acknowledgeDelay
    case addressDeadline
    case proposeNextStep

    var naturalLanguage: String {
        switch self {
        case .acknowledgeDelay:
            return "Acknowledge the delivery delay and the stagnant tracking history."
        case .addressDeadline:
            return "Address the birthday deadline directly and set expectations about whether the package is likely to make it in time."
        case .proposeNextStep:
            return "Offer one concrete next step the support team can take or suggest to the customer."
        }
    }
}

struct ShippingReplyOptions: RequestOptionsRepresentable {
    let mode: ShippingReplyMode
    let requirements: [ShippingReplyRequirement]
}

struct StructuredShippingReplyDraft: AgentStructuredOutput, Sendable {
    let subject: String
    let reply: String
    let urgency: Urgency

    enum Urgency: String, Codable, CaseIterable, Sendable {
        case low
        case medium
        case high
    }

    static let responseFormat = AgentStructuredOutputFormat(
        name: "shipping_reply_draft",
        description: "A concise shipping support reply draft for a mobile support experience.",
        schema: .object(
            properties: [
                "subject": .string(),
                "reply": .string(),
                "urgency": .string(enum: Urgency.allCases.map(\.rawValue)),
            ],
            required: ["subject", "reply", "urgency"],
            additionalProperties: false
        )
    )
}

struct StructuredImportedContentSummary: AgentStructuredOutput, Sendable {
    let title: String
    let keyPoints: [String]
    let followUpAction: String

    static let responseFormat = AgentStructuredOutputFormat(
        name: "imported_content_summary",
        description: "A structured summary of imported content for a share flow.",
        schema: .object(
            properties: [
                "title": .string(),
                "keyPoints": .array(items: .string()),
                "followUpAction": .string(),
            ],
            required: ["title", "keyPoints", "followUpAction"],
            additionalProperties: false
        )
    )
}

struct StreamedStructuredDeliveryUpdate: AgentStructuredOutput, Sendable, Hashable {
    let statusHeadline: String
    let customerPromise: String
    let nextAction: String

    static let responseFormat = AgentStructuredOutputFormat(
        name: "streamed_delivery_update",
        description: "A structured operational delivery update produced alongside visible assistant narration.",
        schema: .object(
            properties: [
                "statusHeadline": .string(),
                "customerPromise": .string(),
                "nextAction": .string(),
            ],
            required: ["statusHeadline", "customerPromise", "nextAction"],
            additionalProperties: false
        )
    )
}

enum DemoStructuredOutputExamples {
    static let shippingCustomerMessage = """
    My package was supposed to arrive yesterday for a birthday on Saturday. Tracking has not moved in two days and I need to know whether it will make it in time.
    """
    static let shippingReplyContext = ShippingReplyContext(
        orderRegion: "Sydney Metro",
        promisedDeliveryWindow: "Expected yesterday",
        eventDeadline: "Birthday on Saturday",
        supportChannel: "In-app premium inbox"
    )
    static let shippingReplyOptions = ShippingReplyOptions(
        mode: .inboxSupport,
        requirements: [
            .acknowledgeDelay,
            .addressDeadline,
            .proposeNextStep,
        ]
    )
    static let shippingContextPreview = """
    Order region: \(shippingReplyContext.orderRegion)
    Promised delivery window: \(shippingReplyContext.promisedDeliveryWindow)
    Event deadline: \(shippingReplyContext.eventDeadline)
    Support channel: \(shippingReplyContext.supportChannel)
    """
    static let shippingFulfillmentPolicyPreview = """
    Mode:
    - \(shippingReplyOptions.mode.naturalLanguage)

    Requirements:
    - \(shippingReplyOptions.requirements.map(\.naturalLanguage).joined(separator: "\n- "))
    """

    static let importedArticleExcerpt = """
    CodexKit is an iOS-first SDK for authenticated agent runtimes, streaming tool use, persona layering, and app-defined integrations like HealthKit and App Intents.
    """

    static let importedArticleURL = URL(string: "https://github.com/timazed/CodexKit")!
    static let streamedStructuredPrompt = """
    The package is delayed ahead of a birthday delivery. Talk to the customer like an in-app support assistant while you work through the situation. Stream a short human-readable response only. Do not restate the final structured delivery fields in prose because the app receives those separately. Then provide the final typed delivery update for the app.
    """

    static func shippingReplyRequest() -> Request {
        do {
            return try Request(
                text: """
                Draft a shipping support reply for the customer message below.

                Customer message:
                \(shippingCustomerMessage)
                """,
                context: shippingReplyContext,
                options: shippingReplyOptions,
                contextSchemaName: "ShippingReplyContext"
            )
        } catch {
            preconditionFailure("Failed to build structured shipping demo request: \(error)")
        }
    }

    static func importedSummaryRequest() -> Request {
        Request(
            prompt: "Summarize this imported content for an app share flow. Return a short title, three concrete key points, and one follow-up action.",
            importedContent: AgentImportedContent(
                textSnippets: [importedArticleExcerpt],
                urls: [importedArticleURL]
            )
        )
    }

    static func streamedStructuredRequest() -> Request {
        Request(text: streamedStructuredPrompt)
    }
}

private struct ProgressiveDemoRecord: Codable, Sendable {
    let id: Int
    let title: String
    let text: String
    static let schema = JSONSchema.object(properties: ["id": .integer, "title": .string(), "text": .string()],
                                           required: ["id", "title", "text"])
}

/// Shared iOS/macOS example. Previews are visibly provisional until the runtime commits.
@MainActor
struct ProgressiveOutputDemoView: View {
    let runtime: AgentRuntime
    var enabled = true
    @State private var previews: [String] = []
    @State private var status = "Choose an output format to stream three small testing tips."
    @State private var rawJSON = ""
    @State private var running = false
    @State private var task: Task<Void, Never>?

    var body: some View {
        GroupBox("Streaming records, XML, and native JSON") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Record and XML cards appear as units close. They are previews until the entire turn validates and is saved.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("JSON Lines") { run(.records) }
                    Button("XML") { run(.xml) }
                    Button("Native JSON") { run(.json) }
                }.disabled(!enabled || running)
                if running {
                    HStack {
                        ProgressView().controlSize(.small)
                        Button("Cancel") { task?.cancel() }
                    }
                }
                Text(status).font(.caption).foregroundStyle(.secondary)
                ForEach(Array(previews.enumerated()), id: \.offset) { index, text in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Unit \(index + 1)").font(.caption.bold())
                        Text(text).textSelection(.enabled)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                }
                if !rawJSON.isEmpty {
                    Text(rawJSON).font(.caption.monospaced()).textSelection(.enabled)
                }
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
        }
        .onDisappear { task?.cancel() }
    }

    private enum Mode { case records, xml, json }
    private func run(_ mode: Mode) {
        guard !running else { return }
        previews = []; rawJSON = ""; running = true; status = "Provisional — waiting for output…"
        task = Task {
            defer { running = false; task = nil }
            do {
                let thread = try await runtime.createThread(title: "Progressive structured output")
                switch mode {
                case .records:
                    let format = AgentRecordResponseFormat(name: "testing_tips", record: ProgressiveDemoRecord.self,
                        schema: ProgressiveDemoRecord.schema, minimumRecords: 3, maximumRecords: 3)
                    for try await event in try await runtime.stream(Request(text: "Give three software testing tips with id 1, 2, 3, a short title, and a paragraph of text. Finish any tool work first."),
                        in: thread.id, output: format) {
                        switch event {
                        case let .format(_, .recordCompleted(_, record)): previews.append(record.title + "\n" + record.text)
                        case .outputCommitted: status = "Committed — all three records validated and stored."
                        default: break
                        }
                    }
                case .xml:
                    let format = AgentXMLResponseFormat(name: "testing_tips", schema: .element("response", children: .sequence([
                        .element("tip", text: .string, attributes: ["id": .required(.integer), "priority": .required(.string(enum: ["low", "high"]))],
                                 occurs: .range(min: 3, max: 3))
                    ])), streaming: .init(identityAttribute: "id"))
                    for try await event in try await runtime.stream(Request(text: "Give three software testing tips, with id 1, 2, 3 and low/high priority. Write a short paragraph in each tip."),
                        in: thread.id, output: format) {
                        switch event {
                        case let .format(_, .elementCompleted(element)):
                            previews.append(element.info.indexedPath + "\n" + element.text)
                        case .outputCommitted: status = "Committed — the complete XML document passed XSD validation and was stored."
                        default: break
                        }
                    }
                case .json:
                    let format = AgentJSONResponseFormat<ProgressiveDemoRecord>(name: "testing_tip", schema: ProgressiveDemoRecord.schema)
                    for try await event in try await runtime.stream(Request(text: "Give one software testing tip with id 1, a short title, and a paragraph of text."),
                        in: thread.id, output: format) {
                        switch event {
                        case let .format(_, .rawJSONDelta(delta)): rawJSON += delta
                        case let .outputCommitted(_, record):
                            previews = [record.title + "\n" + record.text]
                            status = "Committed — native JSON Schema output validated and stored."
                        default: break
                        }
                    }
                }
            } catch is CancellationError { status = "Cancelled — previews are not a committed result." }
            catch { status = "Not committed: \(error.localizedDescription)" }
        }
    }
}
