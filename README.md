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
- `CodexKitDemo`: demo-only integration and mock/live demo pieces

## Recommended Live Setup

The recommended production path for iOS is:

- `ChatGPTDeviceCodeAuthProvider`
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
    authProvider: ChatGPTDeviceCodeAuthProvider(
        configuration: ChatGPTOAuthConfiguration(
            redirectURI: URL(string: "myapp://oauth/callback")!
        ),
        presenter: deviceCodeCoordinator
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

## Demo App

To open the demo app:

```sh
ruby scripts/generate_demo_app_project.rb
open AssistantRuntimeDemoApp.xcodeproj
```

If you need a device-installable bundle ID:

```sh
CODEXKIT_DEMO_BUNDLE_ID=your.bundle.id ruby scripts/generate_demo_app_project.rb
```

The demo app exercises live ChatGPT sign-in, streaming, approvals, and a host-defined tool.
