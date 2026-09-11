# Request preparation and model selection

[Documentation index](index.md) | [Backend configuration](backend-configuration.md) | [Structured recovery](structured-request-recovery.md)

Model choice is a preparation policy, not a recovery feature or a game-specific SDK rule. `CodexResponsesBackend` accepts an optional `CodexModelSelecting` implementation. Apps can use the existing fixed configuration, the built-in ordered account-aware selector, or their own class/actor/closure. A wrapper is optional, not mandatory.

The same preparation capability is used for normal runtime turns and recoverable structured requests. It resolves the effective configuration before model-dependent runtime work. Recovery then saves that decision and the canonical request body; later attempts do not run the selector again.

## Choose the smallest extension point

| Need | API |
| --- | --- |
| Keep today's behavior | Do not supply a selector; use existing backend/thread configuration. |
| Pin one request exactly | Set `Request.modelOverride` to an `AgentThreadConfiguration`. |
| Always use one selected configuration | `FixedCodexModelSelector`. |
| Choose the first supported explicit model/reasoning pair | `PreferredAvailableCodexModelSelector`. |
| Select from host purpose, account policy, or custom requirements | Implement `CodexModelSelecting`, or use `AnyCodexModelSelector`. |
| Keep an existing custom backend wrapper | Delegate `AgentBackendRequestPreparing` and the optional structured recovery adapter. |

There is no magic `.latest` alias or automatic maximum-reasoning downgrade policy. Applications have different priorities for cost, latency, output quality, account eligibility, and input support. The SDK supplies the mechanism and an explicit candidate-order policy; hosts decide those priorities.

## Precedence and lifetime

1. A configuration already resolved for the current prepared request is reused. It is an internal transient value, not a client-supplied serialized override.
2. `Request.modelOverride` is binding and bypasses the selector. It is not permission to degrade to a different model or reasoning level.
3. An opt-in selector receives the inherited thread/backend configuration as its baseline and may select another configuration.
4. Without an override or selector, existing thread/backend defaults remain unchanged.

For an opt-in selector, a thread's saved configuration is the baseline, not a second binding override. If one request must stay pinned, set its explicit override. A selected configuration applies to the prepared request; it does not rewrite the persistent thread's defaults.

Selecting in `beginTurn` alone is too late: the runtime may already have made model-dependent decisions, and a recovery request must be frozen before sending. Move that policy to preparation. The SDK backend also recognizes a resolved selection when called through the prepared runtime path, so a selector does not run twice.

Configuration selection may perform account model discovery, but preparation never sends a generation POST. After any asynchronous policy/catalog work, the runtime checks that the active account binding is still the one used to prepare the request. Authentication tokens are not exposed through the selection context and are not frozen with the request.

## Built-in ordered account-aware policy

Supply an ordered list of complete model/reasoning configurations. The selector picks the first pair that meets the discovered model capabilities and request requirements. If the preferred model supports only a lower reasoning effort, the lower-effort pair must appear explicitly in the candidate list; the SDK does not invent it.

```swift
// These are app-configured AgentThreadConfiguration values.
let selector = PreferredAvailableCodexModelSelector(
    candidates: [preferredConfiguration, lowerEffortConfiguration, fallbackConfiguration]
)

let backend = CodexResponsesBackend(
    configuration: backendConfiguration,
    modelSelector: selector
)
```

The built-in policy uses account-scoped model discovery, supports a refresh policy, and defaults to rejecting an explicitly stale catalog rather than silently guessing. `allowsStaleCatalog` is an explicit host choice. It checks supported reasoning effort, image input when needed, and any minimum context-window requirement. Unknown or unsuitable candidates do not become a hidden fallback.

A catalog is evidence of advertised capabilities, not a guarantee that the next generation will be admitted. Provider entitlements, capacity, and service state can change. A failed POST does not mutate the frozen configuration or start an unbudgeted downgrade cascade. For recovery, a deliberate manual retry with `.reselect` is the boundary at which a host can request a new decision.

## Host-defined purposes and policies

`Request.selectionPurpose` is an optional host-owned string. The SDK does not enumerate purposes or know which domain type corresponds to one. Keep a typed purpose enum or a response-type-to-purpose adapter in your app. The purpose is selection metadata, not text automatically added to the provider prompt.

`CodexModelSelectionContext` provides the purpose, response format, baseline configuration, image-input requirement, optional `AgentModelRequirements`, and a credential-free account binding. Its `models(policy:)` lookup is lazy: a fixed/custom policy that does not need discovery does not incur a catalog request.

```swift
func makeAppSelector(
    detailed: AgentThreadConfiguration,
    economical: AgentThreadConfiguration
) -> AnyCodexModelSelector {
    AnyCodexModelSelector { context in
        let configuration = context.purpose == "detailed-summary" ? detailed : economical
        return CodexModelSelection(
            configuration: configuration,
            policyID: "app-purpose-policy-v1"
        )
    }
}

// Attach metadata to the request your app already constructed.
var request = appRequest
request.selectionPurpose = "detailed-summary"
```

Use an actor conforming to `CodexModelSelecting` for mutable account/preferences state. Return a `CodexModelSelection`, including an optional stable, non-sensitive policy ID for diagnostics. The app may use a class if it satisfies the protocol's concurrency requirements. Policy failure is an error, not permission for the SDK to substitute a different model.

The built-in selector validates candidates against the discovered catalog. Custom selectors can use `context.supports` and the lazy catalog for equivalent checks. The backend also validates explicit/opt-in selections against available known metadata for reasoning/image compatibility and requested context capacity. Unknown capability information is not an entitlement guarantee; host policies that require proof should use discovery and fail explicitly when it is unavailable.

`AgentModelRequirements.minimumContextWindowTokenCount` is a capability floor, not a tokenizer estimate of the full request and not a token reservation. Content fitting and provider rejection remain separate concerns.

Per-request pinning stays explicit:

```swift
var pinnedRequest = appRequest
pinnedRequest.modelOverride = exactConfiguration
```

This bypasses dynamic selection but does not bypass authentication, input validation, or known capability checks. Built-in graceful degradation is therefore opt-in and inspectable rather than a global change to ordinary `send`.

## Existing backend wrappers

An `AccountAwareCodexBackend` can remain the app's public backend. Give its underlying `CodexResponsesBackend` the selector, forward `AgentBackendRequestPreparing`, and delegate the narrow recovery capability:

```swift
extension AccountAwareCodexBackend: AgentBackendStructuredRecoverySupporting {
    public var structuredRecoveryAdapter: AgentStructuredRecoveryAdapter {
        get async throws {
            try await wrapped.structuredRecoveryAdapter
        }
    }
}
```

Here `wrapped` is the app wrapper's existing `CodexResponsesBackend`. Also forward any normal backend capabilities your wrapper already supports, including provider context and model discovery. See the complete compiling [public fixture wrapper](../Tests/RecoveryIntegrationSupport/FixtureApplication.swift); conforming only to recovery while leaving dynamic selection in `beginTurn` does not implement request preparation.

A wrapper can instead implement its own preparation policy and return the effective configuration before delegating transport. The runtime rejects a wrapper that changes a binding per-request override. The returned selection is applied to the local prepared thread/request; the wrapper must honor it on the ordinary send path.

`AgentStructuredRecoveryAdapter` has no public initializer for arbitrary send closures. The SDK creates it from its Responses backend, retaining endpoint checks, same-account credential renewal, authorization immediately before every POST, canonical body integrity, and the tool-free restriction. Wrappers delegate this capability; they do not replace the recovery transport or bypass its guards.

## Frozen recovery versus explicit reselection

A recovery operation persists its effective selection before returning its handle. Subsequent replacements, relaunches, and 401 reissues reuse the exact request body, model, reasoning settings, instructions, and response schema. Current selector behavior is irrelevant to that operation. Fresh credentials remain bound to the original account/source.

`retryStructuredRecovery(..., selection: .preserve)` creates a linked, bounded successor with the same frozen request. `.reselect` deliberately runs preparation for a successor, based on the original request and baseline configuration. A saved explicit override still wins. The original operation's history and budget are not rewritten.

A saved completion does not require model discovery, selection, backend availability, or renewed generation permission. It belongs to its original contract. Retrieve/migrate/commit it instead of selecting a model to recreate it.

## Diagnostics and compatibility

A `model.selected` event records the effective model/reasoning configuration and optional policy ID through existing logging. Recovery events separately identify operation and attempt lineage. Neither event stream is a place for credentials, prompts, or private purpose strings.

These protocols are optional capabilities; ordinary custom backends do not need new methods. Existing backend initializer calls remain valid with the default `modelSelector: nil`. Apps storing exact initializer function references may need a closure because defaulted parameters change the full function type. See [migration](migration.md#host-app-recovery-and-request-preparation).

Domain-specific model tiers, job readiness, UI explanations, gameplay persistence, and telemetry-vendor adapters remain in the host application.
