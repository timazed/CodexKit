import CodexKit
import Foundation

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
