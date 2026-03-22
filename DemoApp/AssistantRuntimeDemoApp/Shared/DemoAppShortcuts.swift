import CodexKit
import Foundation
#if os(iOS)
import AppIntents

enum DemoShareImportExamples {
    static func articleSummaryRequest(
        excerpt: String,
        url: URL?,
        image: AgentImageAttachment? = nil
    ) -> UserMessageRequest {
        UserMessageRequest(
            prompt: "Summarize the imported content in three short bullet points and call out one follow-up action.",
            importedContent: AgentImportedContent(
                textSnippets: [excerpt],
                urls: url.map { [$0] } ?? [],
                images: image.map { [$0] } ?? []
            )
        )
    }
}

private struct ShippingSupportReplyDraft: AgentStructuredOutput {
    let subject: String
    let reply: String
    let urgency: String

    static let responseFormat = AgentStructuredOutputFormat(
        name: "shipping_support_reply_draft",
        description: "A concise shipping support reply draft for an iOS app shortcut.",
        schema: .object(
            properties: [
                "subject": .string(),
                "reply": .string(),
                "urgency": .string(enum: ["low", "medium", "high"]),
            ],
            required: ["subject", "reply", "urgency"],
            additionalProperties: false
        )
    )
}

struct SummarizeImportedContentIntent: AppIntent {
    static let title: LocalizedStringResource = "Summarize Imported Content"
    static let description = IntentDescription(
        "Summarize text, links, and optional images that were shared into the demo app."
    )
    static let openAppWhenRun = false

    @Parameter(title: "Text")
    var text: String

    @Parameter(title: "Link")
    var link: URL?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let runtime = AgentDemoRuntimeFactory.makeRestorableRuntimeForSystemIntegration()
        _ = try await runtime.restore()

        guard await runtime.currentSession() != nil else {
            return .result(dialog: "Sign in to the demo app first, then run the shortcut again.")
        }

        let thread = try await runtime.createThread(title: "Shortcut Summary")
        let request = DemoShareImportExamples.articleSummaryRequest(
            excerpt: text,
            url: link
        )
        let summary = try await runtime.sendMessage(request, in: thread.id)
        return .result(dialog: IntentDialog(stringLiteral: summary))
    }
}

struct DraftShippingSupportReplyIntent: AppIntent {
    static let title: LocalizedStringResource = "Draft Shipping Reply"
    static let description = IntentDescription(
        "Generate a structured shipping support reply draft using CodexKit structured output."
    )
    static let openAppWhenRun = false

    @Parameter(title: "Customer Message")
    var customerMessage: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let runtime = AgentDemoRuntimeFactory.makeRestorableRuntimeForSystemIntegration()
        _ = try await runtime.restore()

        guard await runtime.currentSession() != nil else {
            return .result(dialog: "Sign in to the demo app first, then run the shortcut again.")
        }

        let thread = try await runtime.createThread(
            title: "Shortcut Support",
            personaStack: AgentDemoViewModel.supportPersona
        )
        let draft = try await runtime.sendMessage(
            UserMessageRequest(
                text: """
                Draft a shipping support reply for this customer message.

                Customer message:
                \(customerMessage)
                """
            ),
            in: thread.id,
            expecting: ShippingSupportReplyDraft.self
        )

        let renderedDraft = """
        Subject: \(draft.subject)
        Urgency: \(draft.urgency)

        \(draft.reply)
        """
        return .result(dialog: IntentDialog(stringLiteral: renderedDraft))
    }
}

struct DemoAppShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        return [
            AppShortcut(
                intent: SummarizeImportedContentIntent(),
                phrases: [
                    "Summarize imported content with \(.applicationName)",
                    "Summarize this with \(.applicationName)",
                ],
                shortTitle: "Summarize Import",
                systemImageName: "square.and.arrow.down"
            ),
            AppShortcut(
                intent: DraftShippingSupportReplyIntent(),
                phrases: [
                    "Draft a shipping reply with \(.applicationName)",
                    "Ask \(.applicationName) for a shipping support draft",
                ],
                shortTitle: "Shipping Reply",
                systemImageName: "shippingbox"
            ),
        ]
    }
}
#endif
