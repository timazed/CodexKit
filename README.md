# CodexKit

[![CI](https://github.com/timazed/CodexKit/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/timazed/CodexKit/actions/workflows/ci.yml)
[![Version](https://img.shields.io/badge/release-2.1.0-blue)](https://github.com/timazed/CodexKit/releases/tag/v2.1.0)

`CodexKit` is a Swift SDK for embedding Codex-style agents in **iOS 17+ and macOS 14+** apps. It provides ChatGPT sign-in, persistent conversations, streaming, host-defined tools, and optional local memory.

The optional [`@timazed/codexkit` npm package](#cloud-execution-with-npm) lets Node.js backends execute CodexKit-prepared **text, structured JSON, and image generation/edit requests**. It provides a focused execution bridge for your own middleware. Swift consumers do not need Node or npm.

The latest stable release is [v2.1.0](https://github.com/timazed/CodexKit/releases/tag/v2.1.0).
For upgrades from 1.x or earlier 2.0 alpha snapshots, read the
[migration notes](docs/migration.md). The [1.1.0 documentation](https://github.com/timazed/CodexKit/blob/v1.1.0/README.md)
remains available for existing 1.x integrations.

Version 2.0 brings typed and turn-based streaming output, durable recovery,
separate SQLite and Realm adapters, remote execution, image generation, and
usage telemetry. Version 2.1 adds optional image progress estimates, GPT-6.1 Terra
support, safety-recourse metadata, and more reliable simulator verification.
See the [2.1.0 changelog](CHANGELOG.md#210---2026-10-28) and
[performance report](docs/performance-2026-10-23.md).



## Capabilities

- Text and image input, streamed replies, and turn-based typed output with provisional events and a committed result.
- Resumable threads with SQLite or Realm persistence and context compaction.
- App-defined tools with approval gates, skill-policy limits, and bounded opt-in parallel execution.
- Personas, skills, and local memory for app-specific behavior.
- GPT-6.1 Sol, GPT-6 Sol/Luna/Astra identifiers, account model discovery, and reported usage limits.
- Provider progress, message phases, input added to active turns, and interruption.
- Browser OAuth, device-code sign-in, and read-only reuse of local Codex sessions on macOS.

Your app owns the tools and user interface. The built-in backend uses ChatGPT account access; model availability depends on the account. See the [feature matrix](docs/index.md#feature-matrix) for the full supported surface.

ChatGPT account metadata now resolves namespaced claims and repairs persisted unknown metadata during restoration. See [account metadata compatibility](docs/account-metadata-compatibility.md) for precedence, new plan cases, and integration steps.

## Cloud execution with npm

[`@timazed/codexkit`](packages/codexkit/README.md) exists so a TypeScript backend can execute requests prepared by CodexKit from an API route or worker. It supplies transport, response parsing, output validation, and typed failures. For example, a backend can generate a story, produce schema-validated game data, or generate/edit an image, then store the result for an app to retrieve later. Your backend supplies the queue, durable job storage, and result lookup needed for work to continue after an app disconnects.

The current Cloud release is [**0.2.5**](https://github.com/timazed/CodexKit/releases/tag/cloud-v0.2.5), distributed through GitHub Packages. It supports **Node.js 22 and 24**, CommonJS and ESM imports, and TypeScript declarations, with zero runtime dependencies. It has its own build, tests, and version because it serves Node backends independently of the Swift SDK. Cloud releases use `cloud-v*` tags; Swift releases use `v*` tags.

### What the npm package supports

| Capability | API and behavior |
| --- | --- |
| Plain-text generation | `client.execute(...)` runs one self-contained prepared request and returns the completed answer as `outputText`. |
| Structured JSON generation | The same `execute(...)` API uses the prepared request's native JSON schema and validates the completed output against the supported schema subset. Your app still owns domain/state validation. |
| Streaming progress and usage | Optional `onProgress` callbacks deliver text and reasoning-summary deltas. The completed result includes provider usage when reported; provisional deltas are not a completed result. |
| Image generation and editing | `client.executeImage(...)` returns validated PNG data and actual dimensions. Editing supports up to five inline PNG/JPEG/WebP references. See the [image contract](packages/codexkit/docs/images.md) for the supported model, settings, and limits. |
| Stored failure normalization | `sanitizeCodexFailure` returns a fresh allowlisted failure with static SDK messages, or `undefined`; see the [contract and migration](packages/codexkit/docs/failure-sanitizer.md). |
| Validation, cancellation, and diagnostics | Preflight checks verify prepared bytes, digest, and supported request shape. Execution supports `AbortSignal`, bounded response parsing, and [privacy-safe HTTP failure diagnostics](packages/codexkit/docs/http-errors.md). |

After [configuring GitHub Packages authentication](packages/codexkit/README.md#install-and-use), install the package in your backend:

```sh
npm install @timazed/codexkit
```

Your integration supplies the prepared provider bytes, SHA-256 digest, routing identifiers, and separate per-call authentication. Both text and JSON requests use this entry point; the format comes from the prepared body:

```ts
import { CodexKitBridgeClient } from "@timazed/codexkit";

const client = new CodexKitBridgeClient();
const result = await client.execute({ preparedRequest, authentication });
// result.outputText contains the completed text or validated JSON text.
```

See the [backend guide and supported text subset](packages/codexkit/README.md#supported-text-request-subset), [API route example](packages/codexkit/examples/api-route.ts), and [results/progress contract](packages/codexkit/README.md#results-and-progress).

### Current limits and host responsibilities

- **A limited request executor:** text/JSON requests must be self-contained and tool-free. General tool calling, web search, image input through `execute`, assistant-history migration, previous-response/conversation references, and provider background mode are unsupported. JSON validation supports a bounded schema subset, not every JSON Schema assertion.
- **No full agent runtime:** the npm package does not provide Swift's conversation persistence, personas, skills, memory, tool approvals, or typed JSON Lines/XML decoding. It preserves the prepared model, reasoning, format, and request bytes; it does not discover/select models, repair requests, or generate fallback answers.
- **One provider attempt per call:** there are no automatic retries, sign-in flows, credential refresh, or built-in generation deadlines. The backend owns caller authorization, credential custody, deadlines, retry decisions, job deduplication, storage, and notification delivery. Cancelling local transport does not prove the provider stopped generating.

Swift apps can submit already-prepared packets to mp-api-compatible middleware with `CodexRemoteExecutionClient` and choose silent or regular completion pushes. Runtime request export and automatic conversation/result integration remain separate work; installing the npm package does not supply a hosted service or those integrations. See [remote execution and completion pushes](docs/remote-execution.md).

To explore text, JSON, and images locally, start `npm run dev:api` in `packages/codexkit`. In either Debug demo, open **Structured → Local Cloud → Remote Execution** and choose **Verify All Remote Features** for the 16-job fixture matrix. See [the demo guide](DemoApp/README.md#local-cloud-api-test). For package publishing, see [Cloud release setup](packages/codexkit/docs/releases.md).

## Installation

Swift 6.1 or newer is required; Xcode projects require Xcode 16.3 or newer. The deployment targets remain iOS 17 and macOS 14.

Add `https://github.com/timazed/CodexKit` as a Swift package dependency in Xcode and choose the exact version `2.1.0`, and select the products your app needs:

| Product | Purpose |
| --- | --- |
| `CodexKit` | Core runtime, authentication, backend, tools, and memory APIs |
| `CodexKitUI` | Optional SwiftUI helpers for runtime state and prompts |
| `CodexKitSQLite` | SQLite persistence through GRDB |
| `CodexKitRealm` | Realm persistence through RealmSwift |

Choose one persistence adapter for normal application use. See [persistence integration](docs/persistence.md) for package configuration, storage locations, and migration.

To build and test the package from a checkout on macOS with Xcode installed:

```sh
swift build --force-resolved-versions
swift test --force-resolved-versions
```

The demos are separate Xcode targets; see [Demo Apps](#demo-apps) for their build and offline verification commands.

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

For macOS applications that reuse an accessible local Codex login, see [local session discovery and lifecycle](docs/auth-on-macos.md).

For typed replies and attachments, see [Messaging and images](docs/messaging.md). For model discovery, parallel tools, progress, and turn controls, see [Runtime progress, tools, and turn control](docs/upstream-runtime-features.md).

Signed-in accounts expose an optional `account.name` and `account.displayName`, which falls back to email. See [account names](docs/auth-on-ios.md#account-name).

Turns use bounded event queues and configurable execution limits. The default runtime duration is five minutes, including approval waits; see [event buffering and execution limits](docs/messaging.md#event-buffering-and-execution-limits) for longer workflows.

[Structured recovery](docs/structured-request-recovery.md) preserves a pending attempt when host authorization throws, returning the error without automatic retries or provider credential renewal. Reopen the same handle when the host is ready to authorize it.

## Documentation

The [documentation index](docs/index.md) contains the full guide list, core concepts, and architecture overview. Common next steps:

- [Configure models and reasoning](docs/backend-configuration.md), including typed GPT-6.1 Sol, GPT-6 Sol/Luna, and Daybreak identifiers
- [Use host-managed sessions, execution handles, and async observation](docs/sdk-integration.md)
- [Execute prepared text, JSON, and image requests in a Node backend](packages/codexkit/README.md)
- [Submit remote requests and choose completion pushes](docs/remote-execution.md)
- [Recover saved structured results and authorize bounded replacements](docs/structured-request-recovery.md)
- [Stream and validate typed output (text, JSON, JSON Lines, and XML)](docs/streaming-output.md)
- [Record codec benchmark and compact-format decision](docs/streaming-output-benchmarks.md)
- [Reuse a local Codex session on macOS](docs/auth-on-macos.md)
- [Add memory](docs/memory.md)
- [Define personas and skills](docs/personas-and-skills.md)
- [Integrate App Intents, sharing, and background completion](docs/apple-integrations.md)
- [Configure logging and troubleshoot](docs/logging-and-troubleshooting.md)

## Demo Apps

The native macOS demo includes local Codex session reuse, browser OAuth, device-code sign-in, streaming chat, tools and approvals, typed output, memory, and File/SQLite/Realm persistence. Both demos share `DemoApp/CodexKitDemo.xcodeproj`: select the `CodexKitMacDemo` scheme for macOS or `CodexKitIOSDemo` for iOS. Build and run the signed macOS offline checks with `python3 Scripts/verify_macos_demo.py --mode smoke`. Build and verify the signed iOS simulator app with `python3 Scripts/verify_ios_simulator.py --mode smoke`. See the [demo walkthrough](DemoApp/README.md).

The checked-in iOS app consumes the local package and demonstrates chat, structured output, memory, and Health Coach flows. It includes model refresh, account usage, live progress, **Add to turn**, **Stop**, and a **Parallel Lookups** example.

```sh
open DemoApp/CodexKitDemo.xcodeproj
```

The iOS and macOS demos display the resolved ChatGPT plan, name, email, and account ID for inspecting sign-in and restoration results.

Follow the [demo setup and walkthrough](DemoApp/README.md#try-the-runtime-features).

## Project

- [Structured validation and backend completion](docs/messaging.md#structured-validation-and-backend-completion)
- [Usage telemetry](docs/usage-telemetry.md): token details, partial coverage, retries and saved receipt reuse.
- [Changelog](CHANGELOG.md) and [release conventions](docs/migration.md#versioning-and-releases)
- [Contributing](CONTRIBUTING.md)
- [Security policy](SECURITY.md)
