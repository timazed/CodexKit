# Runtime Architecture

## Goals

Build a small embedded runtime for iOS apps that can:

- authenticate with ChatGPT
- restore auth state securely
- create and resume assistant threads
- stream assistant output into SwiftUI
- register host-owned tools
- require explicit approval for sensitive tool execution

The SDK stays tool-agnostic. The host app owns concrete tools.

## Module Boundaries

### `ChatGPTSessionManager`

Owns:

- current ChatGPT session
- restore from secure storage
- sign-in
- refresh
- logout

Depends on:

- `ChatGPTAuthProviding`
- `SessionSecureStoring`

### `AgentRuntime`

Owns:

- thread creation and resume
- send message
- streaming event fan-out
- tool-call handling
- approval checkpoints
- persisted runtime state

Depends on:

- `AssistantBackend`
- `ChatGPTSessionManager`
- `ToolRegistry`
- `ApprovalCoordinator`
- `RuntimeStateStoring`

### `ToolRegistry`

Owns:

- tool definition registration
- uniqueness/validation
- tool lookup
- execution routing
- normalization into result envelopes

Does not own:

- permissions
- platform APIs
- business rules

### `ApprovalCoordinator`

Owns:

- approval request creation
- host approval callout
- decision normalization

Depends on:

- `ApprovalPresenting`

### `HostBridge`

Aggregates the host-owned dependencies required by the runtime:

- auth provider
- secure store
- backend transport/adapter
- approval presenter
- runtime state store

### `AssistantRuntimeDemo`

Provides demo-only pieces:

- mock ChatGPT auth provider
- in-memory assistant backend
- SwiftUI approval inbox
- SwiftUI-friendly runtime view model

## Public API Surface

## Core Models

```swift
public struct ChatGPTSession
public struct AssistantThread
public struct AssistantTurn
public struct AssistantMessage
public struct ToolDefinition
public struct ToolInvocation
public struct ToolResultEnvelope
public struct ApprovalRequest
public enum AssistantEvent
```

## Host Protocols

```swift
public protocol ChatGPTAuthProviding
public protocol SessionSecureStoring
public protocol AssistantBackend
public protocol AssistantTurnStreaming
public protocol ApprovalPresenting
public protocol RuntimeStateStoring
public protocol ToolExecuting
```

## Runtime Types

```swift
public actor ChatGPTSessionManager
public actor ToolRegistry
public actor ApprovalCoordinator
public actor AgentRuntime
public struct HostBridge
```

## Event Model

The runtime intentionally keeps a smaller event vocabulary than upstream Codex.

### Thread lifecycle

- `threadStarted`
- `threadStatusChanged`

### Turn lifecycle

- `turnStarted`
- `turnCompleted`
- `turnFailed`

### Message streaming

- `assistantMessageDelta`
- `messageCommitted`

### Tooling

- `toolCallStarted`
- `toolCallFinished`

### Approvals

- `approvalRequested`
- `approvalResolved`

## Thread Status Model

Runtime thread state is intentionally mobile-friendly:

- `idle`
- `streaming`
- `waitingForApproval`
- `waitingForToolResult`
- `failed`

This is derived from Codex’s `idle` plus active flags such as waiting on approval or user input.

## Tool Model

The SDK defines how tools work, not which tools exist.

### Registration

Each tool registers:

- stable name
- description
- JSON input schema
- approval policy
- optional approval copy
- executor

### Execution Flow

1. backend emits a tool call request
2. runtime looks up the tool in `ToolRegistry`
3. runtime requests approval when required
4. runtime invokes the registered executor
5. runtime returns a normalized result envelope to the backend
6. backend continues the assistant turn

### Result Envelope

Normalized result shape:

- `invocationID`
- `toolName`
- `success`
- `content`
- `errorMessage`

That keeps host tools interchangeable.

## Approval Model

Approvals are runtime pauses resolved by the host UI.

### Request Shape

Each request contains:

- stable request ID
- thread ID
- turn ID
- tool invocation
- title
- message

### Decision Shape

- `approved`
- `denied`

### Host Responsibility

The host app controls:

- copy
- UI presentation
- any extra risk context

The SDK controls:

- when a request is emitted
- how the active turn pauses/resumes

## Persistence Model

The runtime stores a lightweight snapshot:

- thread list
- last-known thread metadata
- cached messages by thread

This is separate from auth persistence.

### Auth persistence

- secure store only
- Keychain by default

### Runtime persistence

- app-sandbox JSON file or host-provided store

## Backend Boundary

`AssistantBackend` is the runtime-facing transport seam.

It should eventually map to:

- ChatGPT-authenticated network calls
- thread creation/resume APIs
- streaming response transport
- tool result submission

For the first scaffold, the demo backend is in-memory and deterministic. The SDK API is already shaped so a real network backend can replace it later without changing the host-facing runtime API.

## SwiftUI Binding Strategy

The SDK keeps SwiftUI out of the core runtime.

The demo target provides:

- `ApprovalInbox`
- `AssistantDemoViewModel`

That keeps the runtime reusable in UIKit, SwiftUI, or custom state containers.

## Responsibility Split

### SDK owns

- auth/session lifecycle abstraction
- thread lifecycle abstraction
- event model
- tool registration/routing
- approval coordination
- persisted runtime state abstraction

### Host app owns

- actual auth UX implementation
- concrete tool implementations
- native permissions
- approval copy and UI
- app business logic
- storage policy overrides

## First Prototype Shape

The scaffold in this repo implements:

- the runtime module boundaries above
- a mock backend that streams assistant deltas
- a demo tool path that exercises approval plus tool execution
- a SwiftUI-friendly approval inbox and view model

The real production backend and iOS-native ChatGPT auth adapter are intentionally kept behind protocols so they can be swapped in without reworking the runtime surface.
