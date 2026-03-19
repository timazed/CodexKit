# Runtime Architecture

## Goals

`CodexKit` is an embedded agent runtime for iOS apps that can:

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
- `AgentThread`, `AgentTurn`, `AgentMessage`
- ChatGPT auth/session primitives
- backend transport protocols and `CodexResponsesBackend`
- tool types and approval types

### `CodexKitUI`

Owns optional SwiftUI-friendly helpers:

- `ApprovalInbox`
- `DeviceCodePromptCoordinator`
- `AgentRuntimeStore`

This target is optional and does not add any concrete tools.

### `CodexKitDemo`

Owns demo-only pieces:

- mock auth provider
- in-memory backend
- demo runtime factory
- demo view model and SwiftUI screen

## Runtime Boundary

### `AgentRuntime`

`AgentRuntime` is the primary public entry point.

It owns:

- thread creation and resume
- message send
- event streaming
- tool invocation routing
- approval pauses and resume
- persisted runtime state

It is initialized from `AgentRuntime.Configuration`, which contains:

- `authProvider`
- `secureStore`
- `backend`
- `approvalPresenter`
- `stateStore`
- optional `tools`

The old dependency-bag setup is intentionally replaced by this single configuration object.

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
public protocol ChatGPTAuthProviding
public protocol SessionSecureStoring
public protocol AgentBackend
public protocol AgentTurnStreaming
public protocol ApprovalPresenting
public protocol RuntimeStateStoring
public protocol ToolExecuting
```

### Runtime and transport types

```swift
public actor AgentRuntime
public struct AgentRuntime.Configuration
public struct AgentRuntime.ToolRegistration
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
- `turnFailed`

Streaming:

- `assistantMessageDelta`
- `messageCommitted`

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

The demo target should be treated as example integration code, not as required plumbing for host apps.
