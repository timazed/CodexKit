# Interrupted response recovery investigation

Investigated on 10 September 2026 against alpha.27, alpha.28 (`5b73fb7`), and the current checkout (`bde77d5`). This report adds characterization tests and an opt-in provider probe; it does not add a production recovery API.

Follow-up implementation: alpha.29 permits only `.clientManaged` and removes server-side response chaining. The behavior descriptions below record alpha.27/alpha.28 as investigated; see [migration notes](migration.md#client-managed-state-only-alpha29) for the subsequent restriction.

**Recommendation: do not promise remote stream resumption for the authenticated Codex endpoint.** CodexKit currently replays requests and restores conversations; it cannot retrieve or resume an interrupted provider response. The live endpoint rejects the public API's background/stored-response configuration. Recovery GETs encountered a Cloudflare challenge, so the origin's retrieval/resumption capability remains unverified, rather than conclusively absent. Build typed interruption diagnostics and an optional durable local completion receipt first. Enable remote recovery only after a positive endpoint-specific contract/probe.

The reported Pocket POTUS UI message is consistent with multiple failure paths. Without the device error/logs, neither the cause nor the provider's final state can be determined. A client disconnect does not prove that generation failed or stopped at the provider.

## Verified endpoint capabilities

The SDK's default route is `POST https://chatgpt.com/backend-api/codex/responses`. It uses a ChatGPT bearer session and `ChatGPT-Account-ID`. Client-managed requests use `stream: true`, `store: false`, and encrypted reasoning history; they do not send `previous_response_id`. This is separate from `https://api.openai.com/v1/responses`.

Live probes used the existing local ChatGPT session, `gpt-5.6-sol`, a tiny synthetic JSON request, and no tools. Tokens stayed in process memory; no credentials, account identifiers, generated content, or response identifiers are included in the evidence files. No credentials were refreshed or changed. Each diagnostic POST was deliberate, with no automatic retries. These probes do not reproduce the TestFlight device's network or establish a contract for every account or model.

| Operation on the Codex route | Observed result | What this establishes |
| --- | --- | --- |
| Normal structured streaming POST, client-managed | HTTP 200; `response.created`, numbered events, `response.completed` | This account can generate and receive a response ID and sequence numbers |
| Disconnect immediately after `response.created` | ID received, cursor 0; client closes stream | Tests disconnection before visible output; provider's subsequent state is unknown |
| Disconnect after first text delta | ID received, cursor 4 in this probe; client closes stream | Tests a mid-response disconnection; provider's subsequent state is unknown |
| Observe provider completion but withhold terminal event from simulated client | Provider reaches sequence 12; client last delivered cursor is 11 | Models a lost terminal event with known provider completion |
| `GET /responses/{real_id}` | HTTP 403 HTML | No completed-response retrieval was available through the tested route |
| `GET /responses/{real_id}?stream=true&starting_after={client_cursor}` | HTTP 403 HTML | No cursor resumption was available through the tested route |
| `GET /responses/{real_id}` with `Last-Event-ID` | HTTP 403 HTML | No SSE header-based reconnection was available through the tested route |
| POST with `store: true` | HTTP 400 JSON: `Store must be set to false` | `.serverManaged` is not a working recovery workaround on this tested default endpoint |
| POST with `background: true`, `store: false` | HTTP 400 JSON: `Unsupported parameter: background` | The public API background switch is not supported on this endpoint |

GET probes used actual IDs from successful POSTs, including a just-completed response, and the same account/session headers. The final full run also carried the original `session_id`, `x-client-request-id`, and returned opaque `x-codex-turn-state` on every GET. All POSTs supplied that routing state. Inspection confirmed `Server: cloudflare`, `cf-mitigated: challenge`, and challenge HTML for all three recovery GET variants. They are **not** origin JSON 404/405 responses and do not establish response expiration, account mismatch, or permanent provider failure. We did not try to bypass the challenge. A positive authenticated origin response or an authoritative private-endpoint specification is still needed to settle origin capability. WebSocket recovery and any additional private routing requirements remain unverified.

The [official public API background guide](https://developers.openai.com/api/docs/guides/background) documents streaming background requests and cursor reconnection at the public API route. It does not establish Codex endpoint support. Its retention period must not be copied into CodexKit recovery metadata.

The local upstream Codex source snapshot `459a79eb85400af759e9220c7bafb4429ae07516` also exposes POST streaming and WebSocket response creation/continuation. Its `codex-rs/core/src/client.rs` uses a last-response ID to prepare a subsequent incremental request; searches of that client and `codex-api` found no `starting_after`, `Last-Event-ID`, `response.resume`, or response-retrieval implementation. This corroborates a client implementation boundary, not proof of absent private server functionality. Opening a new WebSocket or sending `previous_response_id` is not evidence of resuming the same generation.

Reproduction: `python3 Scripts/probe_response_recovery.py --live --output .build/response-recovery-probe.json`. The probe has a per-socket diagnostic timeout, not an SDK generation deadline. The [final sanitized evidence](response-recovery-probe-2026-09-10.json) records the full run with routing headers and the corrected client cursor. Earlier diagnostic runs are retained locally as `.build/response-recovery-probe.json` and `.build/response-recovery-probe-edge.json`. The first run recorded the provider's final cursor in the withheld-terminal case; subsequent runs explicitly used the simulated client's cursor 11 when querying for the missing event.

## Earlier retry work and alpha.28

| Term | Actual behavior |
| --- | --- |
| Request replay | Another POST with the pass's input. It may start a new generation. It has no verified provider idempotency guarantee. |
| Conversation restoration | Reload local thread/history/provider context, then submit later turns. `resumeThread` does not reconnect to inference. |
| Completed-response retrieval | Fetch an existing final provider response without running inference again. No SDK implementation; endpoint access not established. |
| True stream resumption | Attach to the original provider response after a durable cursor and continue consuming it. No SDK implementation or verified Codex endpoint support. |
| Local completion recovery | Return a durably saved, validated result already received by the SDK but not yet acknowledged by the app. Feasible as an additive feature. |

Commit `bd66f0f` (“Retry dropped streams before committed output,” 26 May) allowed replay after assistant deltas until a message or tool effect became non-replayable. That could duplicate append-only output. Commit `b8c36a9` (“Harden SDK execution, persistence, and provider handling,” 8 September) changed the gate to any visible output. This fix is already in alpha.27 and remains in alpha.28.

Current mechanics:

- A pass builds one request; retries reuse its body and reset pending items, tool outputs, and structured parser state. Earlier successfully completed passes remain in the running turn. Retrying `runtime.send` starts a new turn instead.
- Text deltas, progress, structured snapshots/validation events, assistant commits, and tool requests block automatic replay. “Visible” means emitted by the SDK even if the host's one-shot UI never displays it. Before-output safety only describes observed client output/effects; it cannot prove that an accepted provider request did nothing remotely.
- Premature clean EOF throws `responses_stream_disconnected`. A URL transport failure may remain a raw `URLError`/`NSError`. `response.failed` and `response.incomplete` have separate errors and are not treated as transient disconnects by the default policy.
- `.disabled` means `maxAttempts: 1` for transient retries per model pass. It is not a global network-attempt limit: alpha.28 separately renews authentication and can replay a rejected 401 pass once, including after tools. Runtime initial authentication/context recovery is another layer. No earlier tools are deliberately rerun by that 401 recovery; the host still cannot use `maxAttempts` as a total outbound request counter.
- `response.created` IDs are parsed, then ignored by the runner. `sequence_number` is used to order completed output items, not to checkpoint/deduplicate the event stream. SSE `id:` is ignored. Partial parser state is memory-only.
- Client-managed provider context is committed after a successful turn. Server-managed completed IDs are used for later conversation input, not an unfinished-response checkpoint. Ephemeral turns skip transcript/history/provider-context persistence; they cannot recover their unfinished response after relaunch.
- `Request.clientRequestID` is host correlation, not provider idempotency. Wire `x-client-request-id`, `session_id`, and `prompt_cache_key` use the thread ID. There is no unique durable request/pass recovery record today.
- One-shot structured `send` validates the schema and decodes the value, but returns only after valid turn completion. A full JSON `output_item.done` followed by disconnection still throws. If `response.completed` reaches the runner, it completes without waiting for socket EOF.
- The default turn limit is 300 seconds, separately from `streamIdleTimeout` (default 60 seconds). Use `maximumDuration: nil` for this integration. Removing the generation deadline does not prevent transport failure, OS suspension, or background-task expiration.

The old `testBackendRetriesNetworkLossAfterPartialStreamBeforeCommit` still passes: its URLProtocol synchronously submits bytes and an error, and its assertion observes only the retry's deltas. It does not demonstrate that a consumed partial delta is replayable. The new gated test waits until the consumer receives `Hel` before injecting `networkConnectionLost` or `timedOut`; both fail after one POST with `Hel` emitted exactly once.

Relevant implementation: [request/transport](../Sources/CodexKit/Runtime/CodexResponsesTransport.swift), [runner](../Sources/CodexKit/Runtime/CodexResponsesTurnRunner.swift), [event handling](../Sources/CodexKit/Runtime/CodexResponsesTurnRunner+Events.swift), [authentication recovery](../Sources/CodexKit/Runtime/CodexResponsesTurnRunner+Authentication.swift), [ephemeral execution](../Sources/CodexKit/Runtime/AgentRuntime+TurnExecution.swift), [one-shot validation](../Sources/CodexKit/Runtime/AgentOneShotResponseCapture.swift).

## Recommended SDK boundary

Start with additive typed diagnostics and an opt-in recovery journal, independent of conversation storage. Ephemeral should continue to mean “no conversation/gameplay history”; durable recovery state must be a separate explicit choice, with documented retention and deletion. Do not silently enable prompt persistence for existing ephemeral requests.

The journal should retain:

- A stable logical operation ID, original execution/turn ID, distinct provider-pass/attempt IDs, and immutable resolved request body or a digest plus durable body/attachment references. Replay lineage must distinguish a replacement from the original response.
- Endpoint/provider configuration and capabilities, resolved model, structured schema/name/version, original response ID as soon as received, provider request ID, opaque routing state when required, and the last **durably applied** cursor. Do not invent a cursor or expiry when the provider supplies none.
- Account binding using the SDK's source/workspace/user identity, with fresh credentials resolved for each network operation. Never persist access/refresh tokens in the journal or move recovery to another account after renewal.
- Partial output items keyed by provider IDs and indexes, raw structured bytes or versioned parser state, deduplication records, and any required reasoning/context items. Store cursor and applied state atomically before exposing corresponding events. A raw partial SSE frame is not a completed checkpoint.
- Tool call ID plus argument digest, durable intent/result records, approval state, output delivery state, final provider status, and the complete validated result/receipt. Recovery must restore the tool outputs and completed passes rather than running them again.
- Durable cancellation and host acknowledgement state. A final receipt is retained until explicit app acknowledgement or an explicit retention policy removes it.

A recovery handle should be opaque, Codable, versioned, and refer to that SDK-owned journal. Reopen must validate schema/version, integrity, attachments, endpoint and account binding before returning data or sending anything. Keep credentials separate and protect the journal like other private app data. Persisting only `{responseID, cursor}` is insufficient.

Do not claim exactly-once effects solely from a ledger: an external tool can complete between executing its side effect and saving its result. Such tools need an idempotency key or a reconciliation operation. An unresolved effect intent must stop recovery/replay for host reconciliation. Without that support, restrict initial durable recovery to tool-free structured turns, with built-in web/image tools disabled as well as local tools. This makes a focused Pocket POTUS implementation practical.

Three distinct completion windows matter:

1. Provider completed, terminal event never reached SDK: remote retrieval would be required to establish provider completion. Currently unavailable through the tested route. A valid-looking partial JSON result is not enough.
2. SDK received a terminal event but crashed before recording it: still uncertain unless a raw terminal record was durably journaled first. Reconcile canonical terminal output if supplied; do not assume the current parser retains it.
3. SDK durably recorded completion and validation, app crashed before stage commit/acknowledgement: return the same locally stored result on reopen without a network request. This is the smallest reliable recovery feature to implement now.

The app must commit a stage using the logical operation ID transactionally with its own stage data, then acknowledge the SDK receipt. If it crashes between stage commit and acknowledgement, another delivery is harmless because the app recognizes the committed operation ID. SDK recovery cannot atomically commit another application's gameplay database.

## Outcomes and host retry budget

Proposed typed recovery outcomes must describe both provider state and available actions; `isRetryable` alone is insufficient.

| Outcome | SDK/host behavior |
| --- | --- |
| `completed(receipt, value)` | Require provider terminal completion and schema validation/decoding; local lookup consumes no network attempt |
| `interrupted(metadata)` | Client lost transport; provider status may be unknown. Offer same-response recovery only if that endpoint supports it; otherwise report unavailable |
| `pending(handle, retryAfter)` | Provider confirms queued/running; preserve state for later host-authorized polling; no generation deadline |
| `responseFailed(error)` / `responseIncomplete(reason)` | Original response is terminal; do not try to resume it or return partial output as success |
| `unavailable(reason)` | Unsupported/unverified capability, missing/corrupt checkpoint, missing ID, expired provider state, or missing attachments; no replacement POST |
| `temporarilyUnavailable(details)` | Recovery transport failure/rate limiting/edge challenge; preserve the handle, do not label it expired or terminal |
| `accountMismatch` / `authenticationRequired` | Stop before exposing account-bound data or making requests under a different identity; reconnect the original account |
| `cancelled` | Explicit durable user cancellation prevents further network recovery and automatic result delivery; do not classify as transient disconnect |

Only a provider-authenticated not-found/expiry result under a verified contract should establish unavailable/expired provider state. A 403 edge challenge must not. Local cancellation means CodexKit stops work; it cannot promise remote computation was cancelled without a supported provider cancellation operation. App suspension/process death is not explicit user cancellation.

Let the host supply one async `authorizeNetworkAttempt` callback (conceptual name), invoked immediately before every original POST, recovery GET/attach, or replayed POST, including a 401 reissue and subsequent model passes. The host atomically reserves one of its **three total attempts**, durably and by operation ID. Local receipt lookup and capability/account checks use zero attempts. Authentication refresh itself can have a separate observable auth policy, but its subsequent inference request must not escape the host's budget. Budget denial leaves an interruption/pending handle intact; it is not provider failure or cancellation.

Each explicit `recover` call performs at most one provider recovery operation. Honor retry hints through host scheduling, without hidden polling or nested retry loops. SDK transient retries stay disabled for Pocket POTUS. Keep elapsed time, idle timeout, cancellation, byte limits and attempt limits separate. If true resumption later becomes available, use this callback for every reconnect. Never fall back from `recover` to `send`.

An explicit replay API can follow: `replay(handle, policy: ...)` should check cancellation/account binding, freeze the original resolved inputs, and require a tool-free or demonstrably idempotent/reconciled execution. It allocates a new provider attempt/response identity linked to the same logical operation, debits the same host budget, and emits an explicit replacement/reset notification before any new output. It must disclose that an accepted original may still finish, that compute can be duplicated, and that the new result may differ. “Before output” is not proof of provider-side idempotency.

## Smallest Pocket POTUS integration

With current alpha.28 APIs, configure the existing runtime as follows; `sessionProvider`, `stateStore`, `approvalPresenter`, `DayPreparation`, and `prompt` are the app's existing values/types. This is a single send, not a recovery loop:

```swift
let backend = CodexResponsesBackend(configuration: .init(
    enableWebSearch: false,
    enableImageGeneration: false,
    stateManagement: .clientManaged,
    requestRetryPolicy: .disabled
))
let runtime = try AgentRuntime(configuration: .init(
    sessionProvider: sessionProvider,
    backend: backend,
    approvalPresenter: approvalPresenter,
    stateStore: stateStore,
    turnLimits: .init(maximumToolCalls: 0, maximumDuration: nil)
))
let request = Request(text: prompt, executionMode: .ephemeral)
    .correlated(with: operationID)
let result = try await runtime.send(request, in: threadID,
                                    response: DayPreparation.self)
// App atomically saves result + operationID for this gameplay stage.
```

The app's existing budget must gate every explicit `send`; reusing `operationID` currently only correlates attempts and does not deduplicate or resume them. Do not automatically call `send` again on an unknown-completion error if replacement generation has not been explicitly selected. Existing authentication recovery is still separately bounded, so alpha.28 cannot enforce the proposed aggregate network budget exactly.

For the proposed SDK API, the app-facing recovery path could be this small. **These names are design pseudocode, not alpha.28 declarations:**

```swift
// Initial execution creates a durable SDK handle before its first POST.
// App persists only that handle/operation ID with its pending stage and budget.
let outcome = try await runtime.recover(
    handle, response: DayPreparation.self,
    authorizeNetworkAttempt: { try await retryBudget.reserve(operationID) }
)
switch outcome {
case let .completed(receipt, value):
    try await gameStore.commitStageOnce(operationID, value) // app transaction
    try await runtime.acknowledge(receipt)
default:
    showRecoveryState(outcome) // no implicit replacement request
}
```

The SDK owns preparation/serialization of the recovery handle, cursor parsing, account checks, receipt storage, validation, deduplication and provider transport. The app owns the pending gameplay stage, atomic stage commit, retry authorization and the explicit decision to start a replacement. On this endpoint, the initial implementation of `recover` can return a local completed receipt or an honest unavailable/interrupted result; remote attach must stay capability-gated until verified.

## Controlled transport evidence and remaining acceptance gates

The new [investigation tests](../Tests/CodexKitTests/ResponseRecoveryInvestigationTests.swift) use [a gated URLProtocol](../Tests/CodexKitTests/RecoveryProbeURLProtocol.swift) to inject failures only after consumer-observed events. These are SDK transport characterizations, not mocks offered as proof that a provider supports recovery. Live requests separately exercise actual connection closure and lost-terminal delivery.

Validation result: **58 selected tests passed, zero failures**, including 12 new characterization tests. The full package test target compiled; the complete package test suite was not run. The local log is `.build/response-recovery-tests.log`. Python probe syntax, report links, and `git diff --check` also passed. No production SDK behavior was changed.

| Scenario | Current behavior established by tests |
| --- | --- |
| EOF after `response.created`, before output | Identical POST replay when enabled; one failure when disabled; no cursor/ID retained in error |
| Consumer receives delta, then connection loss or timeout | One POST; delta delivered once; raw URL error lacks typed retry metadata |
| Complete valid JSON item, terminal event withheld | Structured `send` throws disconnection; no unproven success |
| `response.completed` received, socket held open | Structured `send` returns without requiring EOF |
| Completed provider response with invalid structured JSON value | Schema validation rejects it |
| Repeated sequence-number delta | Current output repeats (`HelHel`); no event-level deduplication |
| Cold file-store reopen after ephemeral interruption | Conversation reopens, no saved ephemeral result, no reconnect; explicit send is a new POST |
| Explicit interrupt after output | No retry and no successful turn completion |
| Tool finishes, then transport fails, retries configured to three | Effect executes once; no automatic replay |
| Same tool event repeated after result consumption in ephemeral turn | Synthetic side effect executes twice; a recovery API cannot reuse this path unchanged |
| Provider `failed` / `incomplete` | Distinct non-retryable terminal errors |
| Account/source/user changes and token renewal | Existing `ExternalSessionRuntimeTests` cover persisted binding rejection, renewal between passes, 401 after tools without replaying tools, and disconnect during suspended tool execution |

Run the selected suite with:

```sh
swift test --filter 'ResponseRecoveryInvestigationTests|ExternalSessionRuntimeTests|CodexResponsesBackendTests|AuditRegressionTests.testRetryDoesNotDuplicateVisibleDeltas|CodexUpstreamSupportTests.testPrematureEOF'
```

Before shipping durable recovery, add fault-injection tests for crash between journal apply/cursor advance, terminal receipt write, app stage commit and acknowledgement; repeated/out-of-order/missing events; concurrent recover callers; changed schemas and missing attachments; expired and unknown remote IDs; cancellation before reconnect/during backoff; account changes during recovery; and tools with unresolved side-effect intents. None of these future guarantees is claimed by the current characterization suite. Remote success/expiry tests need positive Codex endpoint capability evidence first; a mocked GET success is insufficient.
