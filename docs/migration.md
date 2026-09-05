# Migration and releases

[Documentation index](index.md) · [CodexKit](../README.md)

Use these notes when moving from earlier 2.0 alpha snapshots. Release history remains in the changelog.

## 2.0 Migration Notes

If you are moving code forward from earlier 2.0 alpha snapshots, update these API areas:

- progress and interruption add event cases
  Update exhaustive ordinary and structured event switches for `progress`, `rateLimitsUpdated`, and `turnInterrupted`, plus status/history switches for `AgentTurnStatus.interrupted` and `AgentSystemEventType.turnInterrupted`. Cancelled turns now record interrupted status, return the thread to idle, and end the stream with `CancellationError`.
- one persistent turn runs per thread
  A concurrent send on the same thread throws `thread_busy`. Use `steer(_:images:in:expectedTurnID:)` to add input for the next model request, or `interrupt(in:expectedTurnID:)` to stop the turn. Ephemeral requests remain independent.
- parallel tools require explicit opt-in
  Existing tools remain serial. Set `ToolDefinition.supportsParallelExecution` for independent calls and configure `maximumParallelToolCalls` on the runtime. Approval-gated tools remain exclusive, and skill tool-policy constraints preserve serial execution.
- incomplete Responses streams fail explicitly
  The built-in backend requires `response.completed`; premature termination throws `responses_stream_disconnected` and follows the existing safe-retry policy.
- persistence adapters are separate SwiftPM products
  Add `CodexKitSQLite` and `import CodexKitSQLite` for the existing SQLite stores, or add `CodexKitRealm` and `import CodexKitRealm` for Realm. The `CodexKit` core target no longer imports or links either database implementation.
- `GRDBRuntimeStateStore` was renamed to `SQLiteRuntimeStateStore`
  The public runtime-store surface now uses `SQLite` naming consistently alongside `SQLiteMemoryStore`.
- request context is now first-class
  Use `Request` with `context:` when you want to attach host-app context separately from freeform prompt text.
- fulfillment policy is request-side
  Use `Request.options` when the app needs to guide how lookup or enrichment work should be performed without putting that policy into user-visible text.
- runtime auth and session storage are concrete
  Configure `AgentRuntime` with `ChatGPTAuthProvider` and `KeychainSessionSecureStore`. Use `AgentRuntime.useSession(_:)` when the app already has a session to load.
- backend turn streaming uses a value type
  Custom `AgentBackend` implementations return `AgentTurnStream`; backend defaults and context-window metadata are asynchronously readable.
- runtime observation is actor-isolated
  Await `observeThreads()`, `observeMessages(in:)`, and related accessors. They return `AgentRuntimeObservationPublisher`; call `eraseToAnyPublisher()` when additional Combine operators are needed.
- memory draft resolution is actor-isolated
  Await `MemoryWriter.resolve(_:)` when validating a draft without writing it.
- memory ranking uses portable profiles
  Replace `MemoryRankingWeights` with `MemoryRankingProfile.importanceThenRecency` or
  `.recencyThenImportance`. Text and structural criteria now decide eligibility independently;
  `MemoryMatchExplanation` reports token coverage and execution method instead of weighted scores.

Example rename:

```swift
import CodexKitSQLite

// Before
let stateStore = try GRDBRuntimeStateStore(url: stateURL)

// Now
let stateStore = try SQLiteRuntimeStateStore()
```

## Versioning And Releases

`CodexKit` uses Semantic Versioning. The latest stable release is `v1.1.0`, while `main` tracks the upcoming 2.0 development line.

### 2.0 Messaging API

The 2.0 line standardizes runtime sends around:

- `stream(...)` for streaming turn events
- `stream(..., response:)` for mixed prose + typed structured stream events
- `send(...)` for final text
- `send(..., response:)` for typed structured replies
- `Request` for turns that combine freeform prompt text with typed host-app context and declarative fulfillment policy

This is the shape new examples and docs target on `main`.

- Release notes live in [CHANGELOG.md](../CHANGELOG.md)
- CI runs on pushes/PRs via [`.github/workflows/ci.yml`](../.github/workflows/ci.yml)
- Pushing a `v*` tag creates a GitHub Release automatically via [`.github/workflows/release.yml`](../.github/workflows/release.yml)
- Tags containing a hyphen, such as `v2.0.0-alpha.1`, are published as GitHub prereleases automatically
- The release workflow also supports manual dispatch for an existing tag if you need to publish a release page after the tag already exists
- Stable releases are cut with annotated tags (`vMAJOR.MINOR.PATCH`)
