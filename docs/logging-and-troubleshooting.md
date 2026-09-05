# Logging and troubleshooting

[Documentation index](index.md) · [CodexKit](../README.md)

Configure developer diagnostics and check common integration problems before shipping.

## Developer Logging

`CodexKit` includes opt-in developer logging for the SDK itself. Logging is disabled by default and can be enabled independently on the runtime, built-in backend, and bundled stores.

```swift
let logging = AgentLoggingConfiguration.console(
    minimumLevel: .debug
)

let backend = CodexResponsesBackend(
    configuration: .init(
        model: .gpt56Sol,
        logging: logging
    )
)

let stateStore = try SQLiteRuntimeStateStore(
    logging: logging
)

let runtime = try AgentRuntime(configuration: .init(
    authProvider: authProvider,
    secureStore: secureStore,
    backend: backend,
    approvalPresenter: approvalInbox,
    stateStore: stateStore,
    logging: logging
))
```

You can also filter by category:

```swift
let logging = AgentLoggingConfiguration.osLog(
    minimumLevel: .debug,
    categories: [.runtime, .persistence, .network, .tools],
    subsystem: "com.example.myapp"
)
```

Available logging categories include:

- `auth`
- `runtime`
- `persistence`
- `network`
- `retry`
- `compaction`
- `tools`
- `approvals`
- `structuredOutput`
- `memory`

Network logging is split between `.debug` and `.verbose` so day-to-day diagnostics stay readable:

- `.debug` includes lifecycle/status breadcrumbs plus the outbound `/responses` request JSON body, important received `/responses` payloads such as final output items and completion/failure events, and `/responses/compact` request/response JSON bodies.
- `.verbose` additionally includes every raw streaming SSE event payload, including token-by-token deltas.

Payload logs may include prompt text, request context, tool arguments, and model output, so use them only for developer diagnostics. Prefer `.debug` when you need request/response visibility without the streaming firehose, and `.verbose` when you need complete wire-level traces.

Use `AgentConsoleLogSink` for stderr-style console logs, `AgentOSLogSink` for unified Apple logging, or provide your own `AgentLogSink`.

Custom sinks make it possible to bridge `CodexKit` logs into your own telemetry or logging pipeline:

```swift
struct RemoteTelemetrySink: AgentLogSink {
    func log(_ entry: AgentLogEntry) {
        Telemetry.shared.enqueue(
            level: entry.level,
            category: entry.category.rawValue,
            message: entry.message,
            metadata: entry.metadata,
            timestamp: entry.timestamp
        )
    }
}

let logging = AgentLoggingConfiguration(
    minimumLevel: .info,
    sink: RemoteTelemetrySink()
)
```

`AgentLogEntry` includes:

- timestamp
- level
- category
- message
- metadata

For remote telemetry or file-backed logging, prefer a sink that buffers or enqueues work quickly. `AgentLogSink.log(_:)` is called inline, so it should avoid blocking network I/O on the caller's execution path.

## Production Checklist

- Store sessions in keychain (`KeychainSessionSecureStore`)
- Use persistent runtime state (`SQLiteRuntimeStateStore`)
- Gate impactful tools with approvals
- Handle auth cancellation and sign-out resets cleanly
- Tune retry/backoff policy for your app’s UX and latency targets
- Log tool invocations and failures for supportability
- Validate HealthKit/notification permission fallback states if using health features

## Troubleshooting

- OAuth sheet closes but app does not update:
  - confirm redirect is `http://localhost:1455/auth/callback`
  - ensure app refreshes snapshot/state after sign-in completion
- Health steps stay at `0`:
  - verify HealthKit permission granted for Steps
  - confirm this is running on a device/profile with step data
- Tool never executes:
  - check approval prompt handling
  - inspect host logs for `toolCallStarted` / `toolCallFinished`
