# Session providers, executions, and async observation

[Documentation index](index.md) · [CodexKit](../README.md)

The existing ChatGPT/Keychain configuration, `send`, `stream`, and Combine observation APIs remain available. The interfaces below support applications that manage their own sessions or need direct ownership of execution and observation.

## Host-managed sessions

`AgentSessionProviding` supplies current credentials, restore, required-session resolution, and unauthorized recovery. A provider can implement only `currentSession()` and use defaults for the other methods when the host supplies a current session and manages renewal elsewhere:

```swift
actor HostSessions: AgentSessionProviding {
    private var session: ChatGPTSession?

    init(session: ChatGPTSession?) { self.session = session }
    func currentSession() -> ChatGPTSession? { session }
    func replaceSession(_ value: ChatGPTSession?) { session = value }
}

let sessions = HostSessions(session: suppliedSession)
let runtime = try AgentRuntime(configuration: .init(
    sessionProvider: sessions,
    backend: backend,
    approvalPresenter: approvalPresenter,
    stateStore: stateStore
))
```

No Keychain store or ChatGPT auth provider is constructed by this initializer. The host owns credential storage and refresh synchronization. Providers that refresh credentials should implement `requireSession()` and `recoverUnauthorizedSession(previousAccessToken:)`, honor cancellation, share concurrent refresh requests, and prevent stale results from overwriting a replacement session. Unauthorized recovery cannot move an existing request to a different account: the runtime cancels if recovery returns another account ID.

Implement `AgentSessionManaging` to support `runtime.signIn()`, `useSession`, and `signOut`; otherwise those actions throw `session_management_unsupported`. `ChatGPTSessionManager` conforms to both protocols and remains the default for the existing auth/secure-store initializer. Each runtime made from that initializer gets its own manager; a supplied provider instance is shared exactly as configured.

Backends continue receiving `ChatGPTSession`, preserving the existing backend protocol. This boundary separates runtime authentication lifecycle from credential storage without changing the session representation. When inspecting configuration, `authProvider` and `secureStore` are now optional and are `nil` for a supplied provider; `sessionProvider` is `nil` for built-in authentication. Existing initializer call sites require no changes.

## Execution handles

Use `start` when you need cancellation or steering tied to one exact execution:

```swift
let execution = try await runtime.start(Request(text: "Plan the work"), in: thread.id)
print(execution.id) // Runtime UUID, available immediately.
try await execution.waitUntilReady()

for try await event in execution.events {
    if case let .assistantMessageDelta(_, _, text) = event {
        print(text, terminator: "")
    }
}
```

`start(..., response: Output.self)` returns an `AgentExecution<AgentStructuredStreamEvent<Output>>`. Plain handles contain `AgentEvent`. Both support ephemeral requests, which can now be cancelled through their own handle without interrupting a persistent turn on the same thread.

- `id` identifies the runtime execution; provider turn IDs still arrive in `turnStarted`.
- `waitUntilReady()` waits for initial backend acceptance without requiring event consumption. It reports startup failures separately from later execution failures. Cancelling a readiness waiter cancels only that wait.
- `cancel()` requests cooperative cancellation of this execution, including during startup, tools, and approvals. An old handle cannot cancel a subsequent execution on the same thread.
- `steer(_:images:)` addresses the captured execution. It fails before readiness, after completion, or when the backend does not support steering.

Each execution has one event consumer. The handle retains its stream; after breaking out of a loop, call `cancel()` if you retain the handle. Releasing all copies of the stream/handle and iterator also cancels the producer. `stream` uses the same execution machinery and returns just the events; `send` collects them. See [event buffering and limits](messaging.md#event-buffering-and-execution-limits).

Cancellation and deadlines also interrupt an accepted backend when the caller has not started consuming events. Backend cleanup completes before the runtime publishes terminal events, so an initially full event queue cannot leave the backend running after the execution ends.

## Async observation

Every `AgentRuntimeObservationPublisher` offers an async sequence. For state snapshots, keep only the newest value:

```swift
let publisher = await runtime.observeMessages(in: thread.id)
let values = publisher.values(buffering: .latest)
for try await messages in values {
    // Replace the displayed snapshot with messages.
}
```

For change notifications, `publisher.values` buffers 64 admitted values and fails with `observation_buffer_overflow` if the consumer falls behind. `values(buffering: .buffered(limit: 256))` changes that bound, clamped to 1–4,096. Admitted notifications drain in order before overflow is thrown. Recover by resubscribing and reloading current state; no changes are silently discarded under this policy.

Subscriptions begin when the sequence is created. Use one consumer per sequence. Cancellation or releasing both the sequence and its iterator unsubscribes from Combine. Keeping an iterator alone keeps the subscription alive. Thread snapshot sequences retain their subscription identity through deactivation and resume, just like existing Combine subscribers.

## HTTP errors and retry metadata

`AgentRuntimeError.code` and `message` remain available. Built-in HTTP failures also include:

| Field | Meaning |
| --- | --- |
| `error.http?.statusCode` | HTTP response status, including 200 when an accepted stream reports a provider failure |
| `providerCode`, `providerType` | Provider error fields when supplied |
| `requestID` | Provider request identifier when supplied |
| `retryAfter` | Parsed server delay in seconds, bounded to one day |
| `error.retry?.attempt`, `maximumAttempts` | Attempt count and configured limit for that model pass |
| `isRetryable` | Whether the failure category is allowed by the retry policy |
| `safety` | `.beforeOutput` or `.outputAlreadyEmitted` |

The Responses runner attaches retry information to its `AgentRuntimeError` failures. Other error types and custom backends may omit it. `isRetryable` does not override exhausted attempts or unsafe replay. Automatic retries honor the longer of local backoff and `Retry-After`, remain cancellable, and stop after visible output or tool effects. Numeric and HTTP-date retry headers are supported; invalid values are ignored and delays are capped at one day. Non-finite retry configuration is normalized before sleeping.

Authentication and context-pressure recovery prefer structured status/code fields. Legacy errors without metadata retain compatible string-based detection. Stored errors from older SDK versions decode with `http` and `retry` set to `nil`. The standalone image-generation client now bounds successful and error response ingestion before decoding.
