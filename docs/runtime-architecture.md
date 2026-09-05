# Runtime Architecture

[Documentation index](index.md) · [CodexKit](../README.md)

## Goals

`CodexKit` is an embedded agent runtime for iOS and macOS apps that can:

- authenticate with ChatGPT
- restore auth state securely
- create and resume agent threads
- stream agent output into app UI
- register host-owned tools
- require explicit approval for sensitive tool execution

The SDK is tool-agnostic. Host apps decide which tools exist.

## Package Structure

### `CodexKit`

Owns the core runtime:

- `AgentRuntime`
- `AgentRuntime.Configuration`
- `AgentEvent`
- `AgentThread`, `AgentThreadConfiguration`, `AgentTurn`, `AgentMessage`
- ChatGPT auth/session primitives
- backend transport protocols and `CodexResponsesBackend`
- tool types and approval types

### `CodexKitUI`

Owns optional SwiftUI-friendly helpers:

- `ApprovalInbox`
- `DeviceCodePromptCoordinator`
- `AgentRuntimeStore`

This target is optional and does not add any concrete tools.

### `DemoApp`

Owns example-app-only pieces outside the package:

- checked-in Xcode app project
- demo runtime factory
- demo view model and SwiftUI screen

Test-only mock auth and backend fixtures live under `Tests/` support code rather than in a package product.

## Runtime Boundary

### `AgentRuntime`

`AgentRuntime` is the primary public entry point.

It owns:

- thread creation and resume
- per-thread model and reasoning defaults
- message send
- event streaming, including provider progress and account-limit updates
- model discovery through capable backends
- active-turn steering and interruption
- tool invocation routing
- approval pauses and resume
- persisted runtime state

It is initialized from `AgentRuntime.Configuration`, which contains:

- `authProvider`
- `secureStore`
- `backend`
- `approvalPresenter`
- `stateStore`
- optional `tools` and `maximumParallelToolCalls` (defaults to four)

The old dependency-bag setup is intentionally replaced by this single configuration object.

Backend configuration supplies default execution settings, while `AgentThreadConfiguration` lets a thread carry its own model and reasoning effort. Future turns resolve those values from the thread first, then fall back to backend defaults.

### Internal runtime plumbing

These concepts still exist internally, but are no longer meant to be first-class app-facing setup types:

- tool registry
- approval coordinator
- turn-session continuation plumbing

Apps interact with them indirectly through `AgentRuntime`.

## Public API Surface

### Core models

```swift
public struct ChatGPTSession
public struct AgentThread
public struct AgentTurn
public struct AgentMessage
public struct AgentTurnSummary
public struct AgentRuntimeError
public enum AgentEvent
```

### Host extension points

```swift
public protocol AgentBackend
public protocol ApprovalPresenting
public protocol RuntimeStateStoring
public protocol ToolExecuting
```

Authentication and session persistence intentionally use the concrete
`ChatGPTAuthProvider` and `KeychainSessionSecureStore` types. Custom backends
return the sendable `AgentTurnStream` value from `beginTurn(...)`.

### Runtime and transport types

```swift
public actor AgentRuntime
public struct AgentRuntime.Configuration
public struct AgentRuntime.ToolRegistration
public struct AgentTurnStream
public struct AgentRuntimeObservationPublisher
public actor ChatGPTSessionManager
public actor CodexResponsesBackend
public struct CodexResponsesBackendConfiguration
public struct ChatGPTOAuthConfiguration
public final class ChatGPTOAuthProvider
public final class ChatGPTDeviceCodeAuthProvider
public final class KeychainSessionSecureStore
public actor InMemoryRuntimeStateStore
public actor FileRuntimeStateStore
```

### Tool and approval types

```swift
public struct ToolDefinition
public struct ToolInvocation
public struct ToolResultEnvelope
public struct ToolExecutionContext
public struct AnyToolExecutor
public struct ApprovalRequest
public struct ApprovalResolution
public enum ApprovalDecision
```

### Optional UI helpers

```swift
public final class ApprovalInbox
public final class DeviceCodePromptCoordinator
public final class AgentRuntimeStore
```

## Event Model

The runtime intentionally keeps a smaller event vocabulary than upstream Codex.

Thread lifecycle:

- `threadStarted`
- `threadStatusChanged`

Turn lifecycle:

- `turnStarted`
- `turnCompleted`
- `turnInterrupted`
- `turnFailed`

Streaming:

- `assistantMessageDelta`
- `messageCommitted` (including optional message phase)
- `progress` (message lifecycle, reasoning summaries, and web-search activity)
- `rateLimitsUpdated` (latest account allowance snapshots, separate from turn token usage)

Tooling:

- `toolCallStarted`
- `toolCallFinished`

Approvals:

- `approvalRequested`
- `approvalResolved`

## Tool Model

The SDK defines how tools work, not which tools exist.

Each tool provides:

- stable name
- description
- JSON input schema
- approval policy
- optional approval copy
- `supportsParallelExecution` (defaults to false)
- executor

Registration happens either:

- up front in `AgentRuntime.Configuration.tools`
- later with `AgentRuntime.registerTool` or `AgentRuntime.replaceTool`

Execution flow:

1. backend emits a tool call request
2. runtime finds the registered tool
3. runtime requests approval when required
4. runtime executes the host-provided tool
5. runtime returns a normalized `ToolResultEnvelope`
6. backend continues the active turn

Consecutive independent calls from the same batch may overlap when their tool definitions opt in. Serial tools and tools requiring approval form barriers; skill tool-policy constraints preserve serial execution. Results retain provider order even when lifecycle events finish out of order.

## Turn control and discovery

One persistent turn may run on a thread at a time. Hosts capture its ID from `turnStarted` or `activeTurnID(in:)`, then use `steer(_:images:in:expectedTurnID:)` to queue input for the next model request, or `interrupt(in:expectedTurnID:)` to cancel it. Interruption records an interrupted turn, returns the thread to idle, clears pending waits, and ends the stream with `CancellationError`. Ephemeral turns remain independent.

`listModels(policy:)` delegates to `AgentBackendModelDiscovering` when supported and otherwise returns bundled metadata. The built-in Responses backend caches account catalogs in memory, supports ETag refresh, and exposes stale/bundled fallback provenance. `rateLimits()` returns the latest observed account limits without issuing a quota request. Typed identifiers include `CodexModel.gpt6Astra`; strings remain open to future server-provided identifiers.

The built-in Responses backend requires `response.completed` before successful completion. Premature stream endings enter the existing safe-retry path; completed messages or tool effects prevent unsafe replay.

See [Runtime progress, tools, and turn control](upstream-runtime-features.md) for examples and compatibility details.

## Recommended iOS Integration Path

For a normal production iOS app, the recommended live stack is:

- `ChatGPTDeviceCodeAuthProvider`
- `KeychainSessionSecureStore`
- `CodexResponsesBackend`
- `FileRuntimeStateStore`
- `ApprovalInbox` and `DeviceCodePromptCoordinator` from `CodexKitUI`
- `AgentRuntimeStore` when the app wants a ready-made SwiftUI-friendly state model

Browser OAuth remains available through `ChatGPTOAuthProvider`, but it is now the advanced path rather than the primary one.

## Demo App

The demo app validates the intended setup:

- live ChatGPT sign-in
- persisted auth/session state
- thread creation and resume
- streamed output
- app-defined tool registration
- approval-gated tool execution
- account model refresh and reported usage allowances
- live progress and message phases
- parallel sample lookups, adding input to a running chat turn, and stopping it

Follow the [demo walkthrough](../DemoApp/README.md#try-the-runtime-features) to exercise these paths.

The demo target should be treated as example integration code, not as required plumbing for host apps.
