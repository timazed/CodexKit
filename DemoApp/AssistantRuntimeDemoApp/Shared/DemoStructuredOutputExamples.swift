import CodexKit
import Foundation

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

enum DemoStructuredOutputExamples {
    static let shippingCustomerMessage = """
    My package was supposed to arrive yesterday for a birthday on Saturday. Tracking has not moved in two days and I need to know whether it will make it in time.
    """

    static let importedArticleExcerpt = """
    CodexKit is an iOS-first SDK for authenticated agent runtimes, streaming tool use, persona layering, and app-defined integrations like HealthKit and App Intents.
    """

    static let importedArticleURL = URL(string: "https://github.com/timazed/CodexKit")!

    static func shippingReplyRequest() -> UserMessageRequest {
        UserMessageRequest(
            text: """
            Draft a shipping support reply for the customer message below. Keep it concise, useful, and realistic for an in-app support inbox.

            Customer message:
            \(shippingCustomerMessage)
            """
        )
    }

    static func importedSummaryRequest() -> UserMessageRequest {
        UserMessageRequest(
            prompt: "Summarize this imported content for an app share flow. Return a short title, three concrete key points, and one follow-up action.",
            importedContent: AgentImportedContent(
                textSnippets: [importedArticleExcerpt],
                urls: [importedArticleURL]
            )
        )
    }
}
