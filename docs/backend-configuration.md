# Backend configuration and models

[Documentation index](index.md) · [CodexKit](../README.md)

Configure the account backend, retries, model selection, reasoning levels, and response-state management.

## Authentication

`ChatGPTAuthProvider` supports:

- `.deviceCode` for the most reliable sign-in path
- `.oauth` for browser-based ChatGPT OAuth

For browser OAuth, `CodexKit` uses the Codex-compatible redirect `http://localhost:1455/auth/callback` internally and only runs the loopback listener during active auth.

## Platform Boundary

`CodexKit` ships a ChatGPT/Codex-style account flow and backend. It does not provide general OpenAI API platform access.

That means:

- built in: ChatGPT sign-in, Codex-style threaded turns, tools, personas, skills, structured output, and optional local memory
- not built in: separate API-key-based OpenAI platform clients, Realtime voice sessions, or other non-Codex API access

If your app needs capabilities outside the built-in backend path, the intended approach is to expose them through your own host tools or custom backend integration.

`CodexResponsesBackend` also includes built-in retry/backoff for transient failures (`429`, `5xx`, and network-transient URL errors like `networkConnectionLost`). You can tune or disable it:

```swift
let backend = CodexResponsesBackend(
    configuration: .init(
        model: .gpt56Sol,
        requestRetryPolicy: .init(
            maxAttempts: 3,
            initialBackoff: 0.5,
            maxBackoff: 4,
            jitterFactor: 0.2
        )
        // or disable:
        // requestRetryPolicy: .disabled
    )
)
```

## Models and reasoning

`CodexResponsesBackendConfiguration` also sets the default model and thinking level for new Codex-backed threads:

```swift
let backend = CodexResponsesBackend(
    configuration: .init(
        model: .gpt56Sol,
        reasoningEffort: .high
    )
)
```

By default, CodexKit manages response state locally. It requests encrypted reasoning items and persists them as opaque provider context so later turns can replay the complete Responses input without exposing reasoning as chat content. To let the backend retain state instead, opt in to server-managed mode:

```swift
let backend = CodexResponsesBackend(
    configuration: .init(
        stateManagement: .serverManaged
    )
)
```

Server-managed mode sends `store: true` and chains turns with `previous_response_id`. Client-managed mode remains the default and sends `store: false` with `include: ["reasoning.encrypted_content"]`.

`CodexModel` provides typed identifiers and bundled fallback metadata. Use `runtime.listModels()` for account-specific picker choices and supported reasoning efforts, `CodexModel.catalog` for all bundled entries, or a known static member directly in configuration:

```swift
let model = CodexModel.gpt56Terra
print(model.rawValue) // gpt-5.6-terra
print(model.info?.contextWindowTokenCount ?? 0)

// Omitting reasoningEffort uses the known model's catalog default.
let configuration = CodexResponsesBackendConfiguration(model: model)
```

| Typed model | Wire identifier | Default effort | Supported efforts | Context |
| --- | --- | --- | --- | ---: |
| `.gpt6Astra` | `gpt-6-astra` | `low` | `low` through `ultra` | 272,000 |
| `.gpt56Sol` | `gpt-5.6-sol` | `low` | `low` through `ultra` | 372,000 |
| `.gpt56Terra` | `gpt-5.6-terra` | `medium` | `low` through `ultra` | 372,000 |
| `.gpt56Luna` | `gpt-5.6-luna` | `medium` | `low` through `max` | 372,000 |
| `.gpt55` | `gpt-5.5` | `medium` | `low` through `xhigh` | 272,000 |
| `.gpt54` | `gpt-5.4` | `medium` | `low` through `xhigh` | 272,000 |
| `.gpt54Mini` | `gpt-5.4-mini` | `medium` | `low` through `xhigh` | 272,000 |
| `.gpt53CodexSpark` | `gpt-5.3-codex-spark` | `high` | `low` through `xhigh` | 128,000 |
| `.gpt52` | `gpt-5.2` | `medium` | `low` through `xhigh` | 272,000 |
| `.codexAutoReview` | `codex-auto-review` | `medium` | `low` through `xhigh` | 272,000 |

The table describes bundled defaults. `CodexModel.userFacingModels` supplies the fallback picker, including GPT-6 Astra. Signed-in apps can discover available models and refresh their metadata:

```swift
let catalog = try await runtime.listModels(policy: .preferCached)
let choices = catalog.visibleModels
// Each choice includes its model, display name, and supported reasoning efforts.
// Use .refresh for an explicit network refresh, or .cachedOnly for no network I/O.
```

Snapshots report their source, fetch time, and whether the metadata is stale. GPT-5.2 remains represented in the complete bundled catalog, while Codex Auto Review is marked for internal use. GPT-5.3-Codex-Spark is marked as a text-only research preview. Actual model access is account- and server-dependent; the catalog is metadata, not an authorization list. See [runtime progress, tools, and turn control](../docs/upstream-runtime-features.md) for discovery, caching, usage limits, and migration details. String-based configuration remains supported, and apps can use `CodexModel(rawValue:)` for a server-enabled or future identifier that this release does not yet know.

`ReasoningEffort.ultra` matches the Codex client setting but maps to the backend-compatible `max` inference value. Ultra's proactive task delegation is a Codex host feature; CodexKit does not add delegation behavior by selecting that effort alone. Unknown non-empty effort strings decode as `.custom(...)` so persisted threads remain compatible with future model-defined values.

Threads can override those defaults with `AgentThreadConfiguration`, and future turns in that thread use the thread configuration:

```swift
let thread = try await runtime.createThread(
    title: "Planning",
    configuration: AgentThreadConfiguration(
        model: .gpt56Terra,
        reasoningEffort: .high
    )
)

try await runtime.updateThreadConfiguration(
    AgentThreadConfiguration(
        model: .gpt56Sol,
        reasoningEffort: .max
    ),
    for: thread.id
)

try await runtime.updateThreadConfiguration(
    for: thread.id,
    reasoningEffort: .medium
)
```
