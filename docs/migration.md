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
- runtime auth supports host-managed sessions
  Existing `ChatGPTAuthProvider`/`KeychainSessionSecureStore` initializer calls remain valid. Alternatively, supply `AgentSessionProviding` and optionally `AgentSessionManaging`. Configuration inspection properties `authProvider` and `secureStore` are now optional. See [SDK integration](sdk-integration.md).
- execution handles and async observation are additive
  Use `start(...)` for a cancellable execution handle, and `publisher.values` for bounded async notifications or `.values(buffering: .latest)` for coalesced snapshots. Existing `stream`, `send`, and Combine APIs remain available.
- runtime and response budgets now have finite defaults
  Turns default to 128 requested tool calls and 300 seconds, including approvals. The backend defaults to 32 model passes and 256 MiB of response bytes. Increase these or use `nil` for workflows that need more; see [execution limits](messaging.md#event-buffering-and-execution-limits).
- one-shot structured output now validates locally before persistence
  `send(..., response:)` and `sendWithSummary(..., response:)` enforce the same schema subset as structured streaming. Unsupported raw assertions fail before starting; invalid replies fail the turn before the assistant reply is saved. Schema violations use `structured_output_schema_invalid`; Swift decoding failures retain `structured_output_decoding_failed`.
- compaction participates in thread operation ownership
  Concurrent persistent turns, compactions, and activation attempts may report `thread_busy`. Deactivation waits for active work; restoring an active runtime reports `runtime_busy`. Compact requests honor the configured response-byte limit and timeout, and authentication recovery cannot change accounts or silently fall back on failure.
- definition loading is bounded and skill policies are validated strictly
  Persona and skill sources default to a 1 MiB limit; inject an `AgentDefinitionSourceLoader(maximumDefinitionBytes:)` with a larger positive value when needed. Malformed JSON skill definitions and invalid or unknown root/policy fields now throw `invalid_skill_definition`. An explicit empty `allowedToolNames` disallows every tool; omit it or use `nil` for unrestricted tools. See [personas and skills](personas-and-skills.md#dynamic-persona-and-skill-sources).
- tool results preserve all text and validate downloaded images
  Every nonempty text block reaches provider requests, fallback replies, and compaction context in order. Remote image downloads must return a successful HTTP status and decodable supported image bytes; HTTP errors, HTML, and truncated payloads are omitted from attachments. Image bytes continue to live in disk blobs, with database references.
- retry metadata is typed
  `AgentRuntimeError.http` and `.retry` preserve status and replay information. Numeric/HTTP-date `Retry-After` is honored. Existing codes and messages remain available, and older stored errors decode with absent metadata.
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

## Public API review against alpha.26

The [8 September release review](release-readiness-2026-09-08.md) compares the current core/UI modules with local tag `v2.0.0-alpha.26`. Ordinary initializer calls remain supported, including the original auth-based configuration initializer. `PublicAPICompatibilityTests` compiles representative previous-release call shapes without `@testable` access.

Seven initializer signatures gained defaulted parameters: definition loading, runtime configuration, runtime errors, turn streams, both backend-configuration initializers, and history queries. Direct calls can omit the new parameters. Code storing an exact initializer as a function value needs a closure because Swift does not apply default arguments to a function reference:

```swift
let makeError: (String, String) -> AgentRuntimeError = {
    AgentRuntimeError(code: $0, message: $1)
}
```

Configuration inspection also changes: `authProvider` and `secureStore` are optional because a host-managed session provider may supply neither. Use optional binding or the runtime's session-management methods. The comparison reports no removed/changed public UI declarations and no new core protocol requirements. These checks concern source migration; they do not establish binary ABI compatibility across alpha versions.

Reproduce the API report locally without changing the checkout:

```sh
python3 Scripts/review_public_api.py --baseline v2.0.0-alpha.26
```

The script compiles isolated baseline/current core and UI modules, then writes Swift API Digester diagnostics under `.build/api-review`. Review diagnostics manually: a defaulted-parameter addition changes a symbol signature even when ordinary calls remain valid.

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
