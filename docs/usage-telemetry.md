# Usage telemetry

[Documentation index](index.md) · [Logging](logging-and-troubleshooting.md) · [Structured recovery](structured-request-recovery.md)

Codex Responses usage is available in `AgentTurnSummary.usage`, individual
`AgentTurnSummary.usageObservations`, and structured recovery status/receipts.
It is collected with logging disabled too. Reading metrics adds no model calls,
changes no request bytes or generation settings, and does not read thread history.

## Fields and units

The mapping follows the ChatGPT-authenticated Codex endpoint and its reference
implementation at Codex revision `48bd7667ca270a8ce7e3e1aa57f88a0f54aee15b`
(`codex-rs/codex-api/src/sse/responses.rs`, including its usage fixture).

| Swift property | Provider field | Unit |
| --- | --- | --- |
| `inputTokens` | `input_tokens` | Tokens, including cached input |
| `cachedInputTokens` | `input_tokens_details.cached_tokens` | Cache-read tokens, included in input |
| `cacheWriteInputTokens` | `input_tokens_details.cache_write_tokens` | Cache-write tokens, separate detail |
| `outputTokens` | `output_tokens` | Tokens, including reasoning |
| `reasoningOutputTokens` | `output_tokens_details.reasoning_tokens` | Reasoning tokens, included in output |
| `totalTokens` | `total_tokens` | Provider-reported tokens |
| `codexRolloutBudgetUnits` | `codex_rollout_budget_units` | Opaque provider units, including fractions |

Do not add cache or reasoning details to the input/output totals. `totalTokens`
is never synthesized. `derivedTotalTokens` explicitly computes input + output
only when both fields have complete coverage and their sum fits in `Int`.
Budget units preserve finite signed values as `Double`; they are not converted to tokens, money, or allowance
percentages. No pricing or subscription-savings calculation is provided.

## Missing values and partial coverage

The original three integer properties and initializer remain source compatible.
Missing input/output/cache-read counts retain their legacy numeric zero fallback;
new consumers must check `availability(of:)` before interpreting those numbers.
New numeric details are optional. In an aggregate, a non-nil value can be a known
subtotal with partial coverage.

| Availability | Meaning |
| --- | --- |
| `unknown` | Legacy record or original initializer: reporting presence was not recorded |
| `unavailable` | No valid observation for that field, including absent or malformed fields |
| `partial` | Some, but not all, responses/attempts supplied that field; value is a known subtotal |
| `complete` | Every contributing response/attempt supplied a valid value, including explicit zero |

`coverage == nil` preserves historical uncertainty, including historical zeroes.
`coverage.responseCount` counts distinct response identities plus attempts with no
response identity. `usageReportedResponseCount` counts usage objects. Per-field
`reportedResponses` counts show exactly how much coverage each scalar has. An empty
usage object is reported but has no field coverage; absent/null usage is not reported.
Malformed fields are omitted and identified by a bounded set of field names in
`invalidMetrics`. Unknown future fields are ignored. Numeric overflow during
aggregation marks the field unavailable in `overflowedMetrics`; it never fails
valid generated output. Optional metrics cannot trigger replacement generation.
Required event envelopes and content retain their existing validation.

For a complete response with input 100, cached input 25, cache writes 60, output 10,
reasoning 5, total 110, and budget units 2.5, those exact values are exposed and all
seven fields have complete coverage. A second pass reporting only input 20,
output 3, and total 23 produces input 120/output 13/total 133 with complete coverage,
while cached input 25/cache writes 60/reasoning 5/budget 2.5 have partial coverage.
A disconnected attempt without usage makes all otherwise known totals partial.

## Response observations and deduplication

Each `AgentUsageObservation` includes `id`, thread/turn, SDK-owned request/pass and
attempt identity, provider response ID when available, model and effective reasoning,
outcome, and usage. Recovery also supplies operation and root-operation IDs.
`requestID` identifies one prepared pass inside the SDK; it is not a provider HTTP
header or the host's arbitrary client metadata. Authentication reissues and retries
have distinct attempt IDs. A new tool/model pass has a new request ID and pass number.

Use `id` (serialized as `usage_id`) to upsert observations. IDs are `response:<id>`
when the provider supplies an ID, otherwise `attempt:<id>`. No exactly-once delivery
is promised. Terminal duplicates contribute once. If a terminal replay fills an
earlier unknown observation for the same response, replace the unknown observation;
do not add both. When a provider omits identity, deduplication is limited to the
SDK-owned attempt. Aggregation state belongs to the current turn/operation.

Completed, failed and incomplete terminal responses retain usable usage. Failed
responses remain failures and keep their existing retry eligibility. An interrupted
stream or rejected attempt without usage is unknown spend, not zero spend. A failed
turn has no success summary; its response observations remain available through
logging, and recoverable operations also persist them in attempt/status metadata.

Turn summaries aggregate their responses and attempts, including transport retries.
Recovery status and receipts aggregate the operation's attempts, including allowed
replacement generations. A manual retry's successor is a separate operation linked
by `rootOperationID`; its aggregate does not include predecessor spend. Never sum
response observations, turn summaries, and operation summaries together.

## Safe operational logging

Enable `.info` logging on the Responses backend for `usage.response.observed`.
Recovery lifecycle events use the runtime's logger. Debug payload logging is not
required. A sink should allowlist the event names and metadata it sends externally.

| Event (`metadata["event"]`) | Scope | Deduplication/use |
| --- | --- | --- |
| `usage.response.observed` | `response` | Upsert `usage_id`; authoritative per-response observation |
| `usage.turn.runner_completed` | `turn` | Existing runner completion log enriched with an aggregate |
| `usage.turn.backend_completed` | `turn` | Existing backend completion log enriched with the same aggregate |
| `usage.turn.completed` | `turn` | Existing runtime completion log enriched with the same aggregate |
| `recovery.receipt.saved` | `operation` | Operation aggregate; `usage_id` is the operation UUID |
| `recovery.receipt.retrieved`, `recovery.receipt.acknowledged` | `operation` | Original aggregate with `usage_reused=true` |

All new usage events carry `event_version=1` and `usage_scope`. Aggregate completion
logs are legacy completion observations, not additional spend. Response logs include
`usage_reused=false`, `outcome`, correlation fields, scalar values only when known,
`<field>_availability`, and `<field>_reported_responses`. Coverage uses
`usage_response_count`, `usage_reported_response_count`, and `usage_reporting`
(`observed` or `unknown`). Invalid/overflow diagnostics contain fixed metric names
only (`usage_invalid_metrics`, `usage_overflowed_metrics`).

The new usage metadata excludes prompts, generated text, reasoning text, credentials,
account identifiers, memory content and arbitrary host metadata. App-specific fields
such as feature/day/version belong in the host's telemetry, joined locally using SDK
identities. Existing debug payload logs remain separate from this operational contract.

## Host integration

```swift
// In your existing event consumer:
if case let .turnCompleted(summary) = event {
    if let usage = summary.usage {
        switch usage.availability(of: .reasoningOutputTokens) {
        case .complete: print("Reasoning tokens:", usage.reasoningOutputTokens ?? 0)
        case .partial: print("Known reasoning subtotal:", usage.reasoningOutputTokens ?? 0)
        case .unavailable, .unknown: break
        }
    }
    for observation in summary.usageObservations ?? [] {
        // Upsert into your recorder using observation.id. Do not also add summary.usage.
        print(observation.id, observation.usage.availability(of: .inputTokens))
    }
}
```

To observe attempts even when a turn fails, configure a safe sink:

```swift
struct UsageSink: AgentLogSink {
    func log(_ entry: AgentLogEntry) {
        guard entry.metadata["event"] == "usage.response.observed" else { return }
        // Upsert approved scalar metadata by entry.metadata["usage_id"].
    }
}
let logging = AgentLoggingConfiguration(minimumLevel: .info, categories: [.network], sink: UsageSink())
let backend = CodexResponsesBackend(configuration: .init(logging: logging))
```

`complete<Output>` and `sendRecovering` retain their existing return types. After
recoverable completion, call `structuredRecoveryReceipt(handle, store:)` for `usage`
and `usageObservations`, or inspect `structuredRecoveryStatus`. Read-only observations,
including those inside status attempts, have `isReused=true`; IDs and values survive
cold reopening. Receipt reads and repeated delivery make zero new transmissions.
Old receipts return nil usage and empty observations. Acknowledgement/abandonment
retain the existing deletion behavior; save any needed metrics in the host before
acknowledging. Frozen bytes, account binding, contracts and retry budgets are unchanged.

## Compatibility and verification

No record version bump or migration is required: persisted additions are optional.
File/SQLite/Realm records retain historical counts with unknown presence. The
TypeScript bridge already preserves optional raw `ExecutionResult.usage`, including
unknown fields; this change adds fixture coverage without a wire or package-version
change. Remote app decoders may consume that existing object independently.

Offline coverage lives in `AgentUsageTests`, `UsageTelemetryTests`,
`StructuredRecoveryTests`, and the second-process recovery fixture. The ordinary
package suites also cover existing request/retry/content behavior. For the enabled
versus disabled byte comparison, the test encoder uses sorted keys because ordinary
JSONEncoder object-key order is unspecified; production encoding is unchanged.

Optional request-size diagnostics are deferred. Instruction previews, existing
`Opening responses event stream` debug `body_length` (final body bytes), and offline
transport capture already support request inspection. No tokenizer, prompt hashes,
raw export API or application-specific prompt framework is added.

### Local verification, 8 October 2026

- `swift test --force-resolved-versions -Xswiftc -warnings-as-errors`: 777 SDK tests
  (seven expected opt-in skips) and 20 recovery integration tests passed.
- Final focused Debug run using the same flags and filter
  `AgentUsageTests|UsageTelemetryTests|CodexResponsesEventPayloadTests|CodexResponsesBackendTests|CodexResponsesBackendRetryTests|StructuredRecoveryTests|RecoveryCompatibilityTests|RecoveryProcessTests`:
  76 SDK tests and eight recovery integration tests passed, including final boundary
  handling, signed fractional units and terminal replay upgrades.
- `swift test -c release --force-resolved-versions -Xswiftc -warnings-as-errors`
  with filter `AgentUsageTests|UsageTelemetryTests|CodexResponsesEventPayloadTests|RuntimePerformanceTests|SDKDesignTests|StorageQueueCancellationTests|StorageLockCancellationTests|RuntimeConcurrencyStressTests|StructuredRecoveryTests|ResponseRecoveryInvestigationTests`:
  77 tests passed, including six concurrency waves per storage adapter.
- `python3 scripts/review_public_api.py --baseline v2.0.0-alpha.39 --output-dir .build/usage-api-review`:
  no breaking declaration diagnostics for CodexKit or CodexKitUI.
- `python3 scripts/verify_macos_demo.py --mode smoke` and
  `python3 scripts/verify_ios_simulator.py --mode smoke --output-dir .build/usage-ios-verification`:
  passed; macOS second-process and iOS 27 relaunch receipt recovery included.
- `npm run verify` in `packages/codexkit`: 202 tests and packed consumer checks passed.
- `python3 scripts/check_source_size.py`: 353 production files within the 600-line limit.
- `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests/Verification`:
  45 tests passed. `git diff --check` passed.

Local logs are in `.build/usage-*.log`; API diagnostics are in
`.build/usage-api-review/`, and iOS reports in `.build/usage-ios-verification/`.
All provider checks used offline fixtures. Swift release `2.0.0-alpha.40` requires
CI verification of the final merged commit on the supported compiler/platform
matrix before release promotion. The TypeScript package remains `0.2.3`.
