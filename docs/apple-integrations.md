# Apple app integrations

[Documentation index](index.md) · [CodexKit](../README.md)

Connect the runtime to iOS background completion, share extensions, App Intents, and Shortcuts. The app owns these integrations.

## iOS Background Completion Window

An interactive SSE turn cannot run indefinitely after iOS suspends its host app. Apps
that want the system's finite background completion window can install the provider
from `CodexKitUI`:

```swift
let runtime = try AgentRuntime(configuration: .init(
    // auth, backend, approvals, and persistence omitted
    authProvider: authProvider,
    secureStore: secureStore,
    backend: backend,
    approvalPresenter: approvalPresenter,
    stateStore: stateStore,
    backgroundActivityProvider: IOSBackgroundActivityProvider()
))
```

The provider starts one iOS background task per active turn and releases it when the
turn completes. If iOS expires the allowance first, CodexKit cancels the turn through
the runtime, backend, and network stream, records the turn as interrupted, then closes the
background task. No background mode entitlement is required for this finite task.

This improves short handoffs such as locking the screen just before a response
finishes, but the system can still suspend or terminate the app. A turn interrupted after
the background allowance expires must be submitted again by the host if the user wants to
retry it.



## Share Extensions And Imported Content

Share extensions stay app-owned, but `CodexKit` now includes `AgentImportedContent` to normalize the content you extract from a share sheet before sending it into the runtime.

```swift
let imported = AgentImportedContent(
    textSnippets: [sharedExcerpt],
    urls: [sharedURL],
    images: sharedImages
)

let request = Request(
    prompt: "Summarize this shared content and call out the next action.",
    importedContent: imported
)

let summary = try await runtime.send(
    request,
    in: thread.id
)
```

That keeps the SDK focused on runtime capability while letting your app own the actual `Share Extension`, `NSItemProvider`, and presentation flow.

## App Intents And Shortcuts

App Intents also stay app-owned, but the demo app now includes working source examples for:

- summarizing imported text/links through `AgentImportedContent`
- generating a typed shipping support draft through `send(..., response:)`

The source lives in:

- [`DemoAppShortcuts.swift`](../DemoApp/AssistantRuntimeDemoApp/Shared/DemoAppShortcuts.swift)

A minimal App Intent shape looks like this:

```swift
struct SummarizeImportedContentIntent: AppIntent {
    static let title: LocalizedStringResource = "Summarize Imported Content"
    static let openAppWhenRun = false

    @Parameter(title: "Text")
    var text: String

    @Parameter(title: "Link")
    var link: URL?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let runtime = try AgentDemoRuntimeFactory.makeRestorableRuntimeForSystemIntegration()
        _ = try await runtime.restore()

        guard await runtime.currentSession() != nil else {
            return .result(dialog: "Sign in to the app first.")
        }

        let thread = try await runtime.createThread(title: "Shortcut Summary")
        let request = Request(
            prompt: "Summarize this imported content in three short bullet points.",
            importedContent: .init(
                textSnippets: [text],
                urls: link.map { [$0] } ?? []
            )
        )

        let summary = try await runtime.send(
            request,
            in: thread.id
        )
        return .result(dialog: IntentDialog(stringLiteral: summary))
    }
}
```
