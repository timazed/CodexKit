# CodexKit

`CodexKit` is a lightweight embedded agent runtime for Apple platforms.

It gives an app:

- ChatGPT sign-in
- secure session persistence
- resumable agent threads
- streamed output
- host-defined tools
- approval-gated tool execution

The core SDK stays tool-agnostic. Your app defines the actual tools.

## Package Products

- `CodexKit`: core runtime, auth, backend, tools, approvals
- `CodexKitUI`: optional SwiftUI-facing helpers

## Recommended Live Setup

The recommended production path for iOS is:

- `ChatGPTAuthProvider`
- `KeychainSessionSecureStore`
- `CodexResponsesBackend`
- `FileRuntimeStateStore`
- `ApprovalInbox` and `DeviceCodePromptCoordinator` from `CodexKitUI`

## Inline Example

```swift
import CodexKit
import CodexKitUI

let approvalInbox = ApprovalInbox()
let deviceCodeCoordinator = DeviceCodePromptCoordinator()

let runtime = try AgentRuntime(configuration: .init(
    authProvider: try ChatGPTAuthProvider(
        method: .deviceCode,
        deviceCodePresenter: deviceCodeCoordinator
    ),
    secureStore: KeychainSessionSecureStore(
        service: "CodexKit.ChatGPTSession",
        account: "main"
    ),
    backend: CodexResponsesBackend(),
    approvalPresenter: approvalInbox,
    stateStore: FileRuntimeStateStore(
        url: FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        .appendingPathComponent("CodexKit/runtime-state.json")
    ),
    tools: [
        .init(
            definition: ToolDefinition(
                name: "get_local_time",
                description: "Return the current local time.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([:])
                ]),
                approvalPolicy: .requiresApproval,
                approvalMessage: "Allow the app to read the current local time?"
            ),
            executor: AnyToolExecutor { invocation, _ in
                .success(
                    invocation: invocation,
                    text: Date.now.formatted(date: .omitted, time: .standard)
                )
            }
        )
    ]
))
```

To give the model built-in web search, enable it on the backend configuration:

```swift
let backend = CodexResponsesBackend(
    configuration: CodexResponsesBackendConfiguration(
        model: "gpt-5.4",
        enableWebSearch: true
    )
)
```

For browser-based ChatGPT OAuth, use the same type with `.oauth(redirectURI: ...)`. If you pass a localhost redirect URI, `CodexKit` will use the internal loopback callback flow automatically on Apple platforms.

## Agent Personality

You can load an app-specific personality by passing custom `instructions` to `CodexResponsesBackendConfiguration`.

```swift
let baseInstructions = """
You are a helpful assistant embedded in an iOS app. Respond naturally, keep the user oriented, and use registered tools when they are helpful. Do not assume shell, terminal, repository, or desktop capabilities unless a host-defined tool explicitly provides them.
"""

let personality = """
You are Atlas, a concise but warm product expert.
Explain tradeoffs clearly, avoid filler, and prefer short actionable answers.
When unsure, say so plainly.
"""

let backend = CodexResponsesBackend(
    configuration: CodexResponsesBackendConfiguration(
        model: "gpt-5.4",
        instructions: "\(baseInstructions)\n\n\(personality)"
    )
)
```

This is the main way to shape tone, style, and behavioral guidance for the embedded agent. If you want user-selectable personalities, keep the shared base instructions and swap the appended personality text when you build the runtime.

## Demo App

The checked-in demo app lives under `DemoApp/` and consumes the local Swift package products through SPM.

![CodexKit demo](preview.png)

To open the demo app:

```sh
open DemoApp/AssistantRuntimeDemoApp.xcodeproj
```

The demo app exercises live ChatGPT sign-in, streaming, approvals, and a host-defined tool.
