# CodexKit

[![CI](https://github.com/timazed/CodexKit/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/timazed/CodexKit/actions/workflows/ci.yml)
[![Version](https://img.shields.io/badge/release-2.0.0--alpha.26-orange)](https://github.com/timazed/CodexKit/releases/tag/v2.0.0-alpha.26)

`CodexKit` is a Swift SDK for embedding Codex-style agents in **iOS 17+ and macOS 14+** apps. It provides ChatGPT sign-in, persistent conversations, streaming, host-defined tools, and optional local memory.

`main` tracks the upcoming **2.0** development line; the latest prerelease is [v2.0.0-alpha.26](https://github.com/timazed/CodexKit/releases/tag/v2.0.0-alpha.26). For the stable release, use the [v1.1.0 documentation](https://github.com/timazed/CodexKit/blob/v1.1.0/README.md). Upgrading an alpha integration? Read the [migration notes](docs/migration.md).

## Capabilities

- Text and image input, streamed replies, and typed structured output.
- Resumable threads with SQLite or Realm persistence and context compaction.
- App-defined tools with approval gates and opt-in parallel execution.
- Personas, skills, and local memory for app-specific behavior.
- GPT-6 Astra identifiers, account model discovery, and reported usage limits.
- Provider progress, message phases, input added to active turns, and interruption.

Your app owns the tools and user interface. The built-in backend uses ChatGPT account access; model availability depends on the account. See the [feature matrix](docs/index.md#feature-matrix) for the full supported surface.

## Installation

Swift 6.1 or newer is required; Xcode projects require Xcode 16.3 or newer. The deployment targets remain iOS 17 and macOS 14.

Add `https://github.com/timazed/CodexKit` as a Swift package dependency in Xcode and select the products your app needs:

| Product | Purpose |
| --- | --- |
| `CodexKit` | Core runtime, authentication, backend, tools, and memory APIs |
| `CodexKitUI` | Optional SwiftUI helpers for runtime state and prompts |
| `CodexKitSQLite` | SQLite persistence through GRDB |
| `CodexKitRealm` | Realm persistence through RealmSwift |

Choose one persistence adapter for normal application use. See [persistence integration](docs/persistence.md) for package configuration, storage locations, and migration.

## Quickstart

The example uses SQLite for persistence. Present device-code prompts and tool approvals from the coordinators in your SwiftUI app; see [authentication on iOS](docs/auth-on-ios.md).

1. Add this package to your Xcode project.
2. Build an `AgentRuntime` with auth, secure storage, backend, approvals, and state store.
3. Sign in, create a thread, and send a message.

```swift
import CodexKit
import CodexKitSQLite
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
    backend: CodexResponsesBackend(
        configuration: .init(
            model: .gpt56Sol,
            reasoningEffort: .low,
            enableWebSearch: true
        )
    ),
    approvalPresenter: approvalInbox,
    stateStore: try SQLiteRuntimeStateStore()
))

let _ = try await runtime.signIn()
let thread = try await runtime.createThread(
    title: "First Chat",
    configuration: AgentThreadConfiguration(
        model: .gpt56Sol,
        reasoningEffort: .low
    )
)
let stream = try await runtime.stream(
    Request(text: "Hello from Apple platforms."),
    in: thread.id
)
for try await event in stream {
    if case let .assistantMessageDelta(_, _, text) = event {
        print(text, terminator: "")
    }
}
```

For typed replies and attachments, see [Messaging and images](docs/messaging.md). For model discovery, parallel tools, progress, and turn controls, see [Runtime progress, tools, and turn control](docs/upstream-runtime-features.md).

Turns use bounded event queues and configurable execution limits. The default runtime duration is five minutes, including approval waits; see [event buffering and execution limits](docs/messaging.md#event-buffering-and-execution-limits) for longer workflows.

## Documentation

The [documentation index](docs/index.md) contains the full guide list, core concepts, and architecture overview. Common next steps:

- [Configure models and reasoning](docs/backend-configuration.md)
- [Use host-managed sessions, execution handles, and async observation](docs/sdk-integration.md)
- [Add memory](docs/memory.md)
- [Define personas and skills](docs/personas-and-skills.md)
- [Integrate App Intents, sharing, and background completion](docs/apple-integrations.md)
- [Configure logging and troubleshoot](docs/logging-and-troubleshooting.md)

## Demo App

The checked-in iOS app consumes the local package and demonstrates chat, structured output, memory, and Health Coach flows. It includes model refresh, account usage, live progress, **Add to turn**, **Stop**, and a **Parallel Lookups** example.

```sh
open DemoApp/AssistantRuntimeDemoApp.xcodeproj
```

Follow the [demo setup and walkthrough](DemoApp/README.md#try-the-runtime-features).

## Project

- [Streaming validation and backend completion](docs/messaging.md#streaming-validation-and-backend-completion)
- [Changelog](CHANGELOG.md) and [release conventions](docs/migration.md#versioning-and-releases)
- [Contributing](CONTRIBUTING.md)
- [Security policy](SECURITY.md)
