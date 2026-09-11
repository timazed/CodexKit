# Structured request recovery for host apps

[Documentation index](index.md) | [Model selection](request-preparation-and-model-selection.md) | [Migration](migration.md#host-app-recovery-and-request-preparation)

Structured recovery is an opt-in API for independent, ephemeral, tool-free structured requests. CodexKit owns the saved request, its account binding, attempt accounting, transport, and validated local completion. The host owns the logical job, whether its result remains applicable, and the transaction that commits it.

This is **local request recovery and replacement generation**, not remote stream resumption. There is no provider response retrieval endpoint behind a recovery handle. A provider response ID and sequence cursor are diagnostic information, not a promise that the unfinished response can be retrieved.

## What recovery adds to ordinary retries

Ordinary `send` retains its existing transient retry/backoff behavior. It is appropriate when the caller can keep the operation alive and does not need durable delivery. Its safe replay rules still prevent retrying arbitrary emitted output or tool effects.

Recovery adds durable identity, a frozen request, a total attempt budget and cooldown that survive relaunch, a separate authorization gate for every generation POST, and a saved completed-result receipt. An interrupted tool-free structured request can be replaced because no partial output or tool effects are published. A saved completion can be delivered again without another generation.

There is one recovery operation per independent host job, not one per screen or batch. If three jobs run concurrently and one fails, reopen or explicitly retry only that job. Keep the completed jobs' handles and receipts. CodexKit does not own batch readiness or roll back unrelated results.

| Behavior | Ordinary retry | Structured recovery |
| --- | --- | --- |
| Default use | Existing `send` callers | Explicit opt-in |
| Lifetime | Current execution | Saved operation across executions/processes |
| Mid-stream structured disconnect | Existing safe replay policy | Authorized replacement, no partial publication |
| Request configuration | Normal turn preparation | Effective configuration and body frozen before generation |
| Retry accounting | Configured in-process policy | Persisted total POST budget and per-attempt authorization |
| Completed delivery | Current call | Validated local receipt until acknowledgement/abandonment |
| Host side effects | Host responsibility | Still host responsibility; receipt delivery is repeatable |

## Backend preparation and wrappers

Use `CodexResponsesBackend` directly or a wrapper that delegates `AgentBackendStructuredRecoverySupporting.structuredRecoveryAdapter`. A wrapper with dynamic configuration also delegates `AgentBackendRequestPreparing`, or implements preparation using its host policy. See [request preparation and model selection](request-preparation-and-model-selection.md) and the [public fixture backend](../Tests/RecoveryIntegrationSupport/FixtureApplication.swift).

Recovery uses the SDK-owned adapter, not an arbitrary wrapper's `beginTurn`. The adapter keeps endpoint validation, account binding, fresh authentication, transport authorization, and tool restrictions inside CodexKit. Delegating it does not delegate permission to bypass those gates. Other providers do not become recoverable merely by conforming to the ordinary backend protocol.

Preparation resolves the host's selection once and saves the effective model/reasoning configuration, instructions, response contract, input, and canonical Responses body before any generation. Credential values are not part of that body. Every replacement uses the saved body, including an authentication reissue. A changed selector or newly available model cannot silently change an existing operation. Endpoint changes are blocked. Credentials can rotate only within the original session binding.

Recovery rejects persistent-thread requests and required tools, disables built-in tools, and rejects unexpected tool activity instead of executing it. It publishes no partial structured value, text deltas, narrative substitute, or tool effects. It does not impose an elapsed-time generation deadline. Transport failures, caller cancellation, and operating-system background expiration still interrupt execution; `expiresAt` controls authorization of a new attempt, not the duration of an already-running generation.

## The host handoff

Use `AgentStructuredRecoveryStore` in an application-private durable directory. Keep it separate from gameplay/application state, with a host-owned association between a stable job key, input revision, contract version, and handle. The [executable integration fixture](../Tests/RecoveryIntegrationFixture/main.swift) and its [host store](../Tests/RecoveryIntegrationSupport/FixtureApplication.swift) show the complete public-API flow.

1. Prepare a recovery operation. Preparation persists the SDK record without sending a generation request. Supply a bounded `maximumAttempts`, and optionally a retry policy, scope, stable host job ID, input revision, and host contract version.
2. Persist the returned handle in the host's job transaction **before calling `sendRecovering`**. If that transaction fails, do not send. Retain or explicitly abandon the orphaned SDK record.
3. Call `sendRecovering(handle, response: Output.self, store: store, ...)`, authorizing each attempt through its callback. On reopening, use the same handle. If a compatible completion is already saved, this returns it without a generation POST, selector invocation, or attempt authorization callback.
4. Commit the result in a host transaction that checks the current lifecycle, account, job applicability, and expected input revision, and atomically marks the logical job committed. Use the stable job/revision as the idempotency key, **not the operation ID**: explicit manual retries create new operation IDs for the same job.
5. Call `acknowledgeStructuredRecovery` only after that transaction succeeds. If the host has already committed, acknowledge without applying the result again. If the result is deliberately no longer applicable, explicitly abandon it rather than falsely recording a gameplay commit.

Do not acknowledge in a `defer` block around decoding or committing. Do not acknowledge merely because the request returned successfully. Keep the handle associated with the host's committed marker until your host cleanup policy no longer needs it.

### Exactly where durability begins

There are two separate durable boundaries: the saved request makes an operation restartable; the saved validated completion makes its result recoverable. Merely finishing on the server, receiving a response ID, or receiving bytes does not cross the completion boundary.

| Crash/interruption boundary | Recovery behavior |
| --- | --- |
| Before SDK request persistence succeeds | No usable handle has been handed off. Preparation must be retried deliberately. |
| SDK record saved, before host stores handle | No generation has been started by preparation. Reconcile the orphan through host metadata/inventory, or abandon it. |
| Host handle saved, before attempt authorization | Reopen the same operation. Its original budget remains. |
| Pending attempt ID saved, before/during host authorization | The callback may be repeated with the same operation/attempt ID. Host authorization must be idempotent. |
| Authorized attempt count saved, before/while sending | That attempt remains spent even if transmission or server acceptance is uncertain. Budgets are conservative, not a billing ledger. |
| Server completed, but response never arrived locally | The completion cannot be recovered by this API. Only an authorized replacement within the remaining budget is possible. |
| Validated completion received, but local receipt persistence failed | CodexKit does not return it as a successful recoverable result. The unavailable local completion cannot be retrieved later. Surface/fix the storage failure before a host decides to continue. |
| Validated completion saved, before host commit | Reopen and read the saved receipt. No generation is needed. |
| Host commit succeeded, before acknowledgement | Re-deliver the receipt, recognize the existing host job/revision commit, and acknowledge without duplicating side effects. |
| Acknowledgement marker saved, before payload removal | The operation is acknowledged and cannot generate again. Repeating acknowledgement completes removal. |

Writes use synchronized temporary files and atomic replacement. These guarantees address application/process interruption on a functioning local filesystem; they are not a guarantee against device loss, restored backups, filesystem corruption, or unavailable protected storage. Do not put the recovery directory on an unsupported shared/network filesystem and assume cross-device exactly-once execution.

## Lifecycle suspension and permanent cancellation

`Task.cancel()` on the owning `sendRecovering` task suspends the operation and throws `CancellationError`. Runtime sign-out interruption and background-task expiration also stop the active execution without resetting its budget. A host can explicitly call `suspendStructuredRecovery` from another runtime instance using the same store, including while a generation or authorization callback is active.

Suspension preserves the saved request, consumed attempts, cooldown, diagnostics, and any already-persisted completion. Once the old execution has unwound, reopen with `sendRecovering` to read that completion or request an authorized replacement within the remaining budget. A suspended operation with no budget does not gain one by resuming.

`cancelStructuredRecovery` is the separate, explicit permanent decision. It fences off late delivery and future generation, including manual retry from that operation. Saved alpha.30 records already marked cancelled remain terminal. Use abandonment when the host also wants to remove the retained content.

The SDK checks the lifecycle at authorization, transmission, completion persistence, and delivery. A separate lifecycle command record lets another execution stop the owner without waiting for its operation lease. A cooperative monitor cancels active transport. The exclusive operation lease is held until the previous execution unwinds; a second sender receives `operationBusy`, never a competing generation.

An authorization callback must cooperate with cancellation. Stopping the task does not make an arbitrary host callback interruptible. The callback can still finish later, but lifecycle/account checks prevent that late answer from authorizing a POST. Never wait for the same operation to finish from inside its callback.

No SDK check can make a return and an unrelated host database transaction atomic. If the app becomes inactive after the SDK returns, the host must reject that late commit itself. The fixture's host transaction checks its active state and revision for this reason.

## Durable budgets, backoff, and authorization

`maximumAttempts` is the total number of generation POST reservations, including the initial request and a 401 authentication reissue, not a number of retries in addition to the initial request. It is bounded to 1...1000. Ordinary backend retry settings cannot multiply this budget: the recovery path owns replacement scheduling and disables its inner transient retry loop.

The SDK saves a pending attempt ID before asking the host for authorization. After approval, it rechecks the lifecycle, account, expiration, and remaining budget, then persists the consumed attempt before permitting transmission. Record the host's decision by operation ID and attempt ID. An authorization callback replay is not a new host charge. Conversely, an already-spent attempt is never refunded just because a crash makes transmission uncertain.

The saved `AgentRecoveryRetryPolicy` controls replacement-eligible failures and backoff. `nextAttemptAt` persists the selected delay, including applicable server `Retry-After`. Reopening waits for the same cooldown rather than bypassing rate limiting. There is no elapsed-time generation deadline. The application can suspend instead of leaving a task waiting.

A callback denial is not permanent cancellation and does not spend a generation attempt. Keep the handle and resume when authorization is possible. The pending attempt ID remains stable. Do not wrap a recovery operation in an application loop that discards its handle or resets its budget on each failure.

### Failure-specific behavior

| Failure | Automatic behavior within the saved budget | Host action |
| --- | --- | --- |
| Network loss, timeout, premature EOF/missing completion | Eligible transport interruptions can trigger a tool-free replacement after backoff. Partial output is discarded. | Inspect the underlying transport cause; suspend while offline or reopen the same handle. |
| HTTP 429 | Apply configured retry policy and persist server cooldown. | Wait/resume; an exhausted budget requires deliberate manual retry. |
| Recognized quota, credit, or spending-limit exhaustion | Initial `quota_exceeded`, even for HTTP 429. Reopening reports `permanentlyFailed`, retaining the quota cause in `status.lastFailure`; no replacement or new authorization. | Resolve the account limit, then deliberately request an eligible bounded manual retry. |
| Retryable HTTP provider failure | Replace only for configured retryable statuses and within budget. | Use typed HTTP/provider diagnostics; do not treat every server error as transient. |
| HTTP 401 | Attempt existing same-account authentication recovery; a reissued POST consumes another authorization and attempt. | If renewal is unavailable/fails, sign in to the same account/source before reopening. |
| HTTP 403 or nonretryable HTTP rejection | No blanket refresh or automatic downgrade. | Correct authorization/configuration or explicitly initiate an eligible manual retry. |
| Provider `response.failed` | Automatic replacement only for explicitly allowed provider failure codes. | Surface the code and choose a deliberate retry policy. |
| Invalid JSON, schema violation, Swift decoding failure | Terminal by default; no partial value or narrative fallback. An explicit retry policy can opt into invalid-output replacement. | Fix/migrate the contract or perform an explicit bounded manual retry. |
| Tool activity or execution-limit violation | No automatic replacement that could repeat effects. No tools are executed by recovery. | Correct the request/integration rather than bypassing the safety restriction. |
| Authentication expires or account changes while waiting/streaming | Stop unsafe work; do not deliver a result to a different account. | Reauthenticate the original binding, or explicitly abandon/purge according to host policy. |
| Owning task ends or background execution expires | Suspend, retaining budget and saved completion. | Reopen only in an active host lifecycle. |
| Store unavailable, quota exceeded, corrupt/unknown record | Fail closed, without treating a missing receipt as permission to regenerate. | Restore storage/access or make an explicit host recovery decision. |

`AgentRuntimeError` still carries `code`, HTTP and retry metadata, and optional `interruption`. The interruption preserves transport domain/code, provider response ID, sequence cursor, and output/tool activity. Use those typed fields for recovery decisions and player-facing explanations; do not parse strings or assume all failures are `URLError`. Cancellation remains `CancellationError`. Persistence and recovery policy errors remain distinguishable from transport errors.

## Explicit manual retry

Use `retryStructuredRecovery` only after a deliberate user decision. It returns a new handle; it does not start generation. The successor has a fresh bounded budget and links to the previous/root operation for diagnostics. The source's history and consumed budget are not reset.

```swift
// The host persists this action ID before requesting a successor.
let retryHandle = try await runtime.retryStructuredRecovery(
    failedHandle,
    retryActionID: savedUserActionID,
    store: recoveryStore,
    maximumAttempts: 2,
    selection: .preserve
)
// Persist retryHandle for the same logical job/revision before sending it.
```

The source stores the successor reservation before the child is created. Repeating the same action and settings returns or completes creation of the same child, even after a crash between those writes. A different action against the same source is rejected; subsequent deliberate retries operate on its successor. A repeated action with changed settings is rejected rather than silently changing a budget.

`.preserve` keeps the frozen body and configuration. `.reselect` runs preparation again using the original request and baseline configuration, then freezes the successor. It is an explicit policy boundary, not an automatic response to model unavailability. A saved explicit per-request model override remains binding during reselection. Changing the prompt, schema, purpose, or application revision is a new host request, not a retry mutation.

| Source condition | Manual retry behavior |
| --- | --- |
| Exhausted, eligible terminal failure, expired attempt permission, or configuration-blocked | May create one linked successor with explicit new settings. |
| Suspended with attempts left | Resume the original operation; suspension alone does not authorize a new budget. |
| Suspended and exhausted | Deliberate manual retry can create a successor. |
| Completion saved | Retrieve/commit/migrate that receipt; do not generate a duplicate. |
| Permanently cancelled | Terminal. Manual retry from that operation is rejected. |
| Acknowledged, abandoned, missing, corrupt, or unsupported record | Cannot clone an unavailable request. Restore/reconcile the host job first. A new request requires a separate explicit host decision, not a fallback hidden inside retry. |
| Wrong account or sign-in required | Retry cannot copy another account's request or bypass authentication. |

If a record is unavailable, the host may still retain a prior operation ID for diagnostics on a separately prepared request. That link is not proof of the old budget, receipt, or completion. Never infer that the job was uncommitted solely because its SDK record is missing.

## Status and diagnostics

`structuredRecoveryStatus` can be read while the operation is active. It does not take the long-lived execution lease and it does not generate, renew credentials, or run model selection.

Use its independent dimensions rather than reducing recovery to a boolean:

- State and availability distinguish ready, running, waiting, replacement eligible, completion saved, suspended, exhausted, authentication required, permanently cancelled, failed, expired, acknowledged, abandoned, and blocked.
- Blockers distinguish authentication/account, configuration, incompatible contract, and storage conditions. A blocker can coexist with remaining budget; clearing it does not reset that budget.
- `hasSavedCompletion` is independent of lifecycle status. A suspended execution can already have a saved result that the next active lifecycle should retrieve.
- Attempt counts, remaining budget, `nextAttemptAt`, and expiry explain when a new attempt is possible.
- Operation/root/previous IDs, attempt IDs and summaries, provider response IDs, cursor, and typed failures support diagnostics. A transmission-authorized state is not proof of server acceptance.
- Suggested actions help hosts choose wait, resume, read receipt, sign in, manual retry, acknowledge, or abandon. They are a snapshot, not an authorization token; mutating operations recheck the current state.

Account-mismatched or signed-out status is redacted. Inventory can expose unreadable record IDs for host reconciliation without deleting their contents. A stale running record after process death is presented as interrupted when no owner holds its operation lease.

Structured `recovery.*` events use the existing `AgentLogSink`, the `recovery` category, and an event-version field. They include operational identifiers, counts, selected configuration, and safe typed error codes. They do not include prompt/result text, tokens, authorization headers, account identifiers, host scope/job strings, or arbitrary provider error messages. Hosts can adapt this sink to their telemetry system; CodexKit has no dependency on any telemetry vendor.

Telemetry is best-effort diagnostics, not the authoritative attempt ledger or host commit log. Sink implementations should be fast, nonblocking, and must not reenter the same operation synchronously. Detailed error objects returned through the API may contain provider messages; apply your own privacy policy before forwarding them.

## App upgrades and incompatible receipts

A recovery record owns its original response schema and optional host contract version. Do not deserialize an old receipt as the app's newest type and interpret a decoding failure as permission to regenerate.

`sendRecovering` compares the requested structured format to the saved format before generating or returning a typed result. Supply `expectedContractVersion` when identical JSON shapes can mean different things to different app versions. A mismatch fails without consuming an attempt or removing the receipt.

`structuredRecoveryReceipt` exposes the validated payload and original format/version, account binding, host job/revision, lineage, and completion time. It does not need a live model selector, a recovery-capable backend, or unexpired generation permission. It still enforces account and permanent-cancellation restrictions. Decode using the original type, migrate in the host, and commit idempotently before acknowledgement.

If the host cannot migrate a contract, retain the receipt and show an explicit unsupported-result state. Offer a supported app version or an explicit abandonment/new-request decision. Never silently delete progress or repeatedly attempt a generation that cannot repair a local compatibility problem.

Version-1 alpha.30 records retain IDs, consumed attempts, saved completions, and permanent cancellation. Pending requests are upgraded conservatively; version 1 did not store the canonical wire body. Unknown versions are not interpreted or deleted. See [migration details](migration.md#host-app-recovery-and-request-preparation).

## Retention and cleanup

Prompts, input images, instructions, schemas, and generated responses can be sensitive and large. Use an app-private directory with appropriate platform protection and backup policy. The store applies restrictive file permissions/protection where supported; this is not a claim of application-level encryption.

- Acknowledge after host commit to remove the saved request and response, retaining a small disposition marker for idempotent acknowledgement/status.
- Explicitly abandon an obsolete job/campaign result when the host decides it is not applicable. Stop and await active work first; cleanup never steals an executing operation's lease.
- Use host scope metadata for independent retention decisions. Account/source changes never silently delete another account's progress.
- `purgeAccount(_:scope:)` is an explicit store-maintenance decision and can use the host's retained binding after sign-out. It removes matching idle records and disposition/control data, reporting busy/unreadable items rather than guessing their ownership.
- `cleanupDisposed(before:for:)` removes old disposition/control metadata for the chosen account. It does not automatically evict unacknowledged completions or unfinished requests.
- Once a disposition marker is removed, status is unavailable. The host's durable committed-job marker remains the authority on whether to apply gameplay again.
- The default store quota is 512 MiB, with a 128 MiB per-record limit. Choose a suitable quota and surface quota/storage errors. Filling the store never triggers silent eviction or successful delivery of an unsaved completion.
- Lock files intentionally remain to preserve lock identity across processes. Once an entire account/scope directory is inactive and no process holds it, the host may retire that directory as a separate maintenance action.

Retention is explicit rather than an elapsed-time generation policy. If cleanup skips a busy or unreadable item, retain that diagnostic and reconcile later; do not report its sensitive data as removed.

## Integration verification

The fixture imports public `CodexKit` APIs, delegates through a custom backend, selects by host purpose, and commits independent jobs by stable job/revision. Controlled transport replies assert exact request counts and canonical body equality without a live provider account.

Run the integration and legacy recovery coverage:

```sh
swift test --filter 'CodexKitRecoveryIntegrationTests|StructuredRecoveryTests'
```

Coverage includes concurrent independent completions, mid-stream disconnects, persistent exhaustion, explicit idempotent retry/reselection, task suspension/reopen, cross-runtime permanent cancellation, callback reservation replay, persisted rate-limit cooldown, same-account token renewal, account changes, invalid output, quota failure, schema/version compatibility, retention, and privacy-preserving telemetry.

`RecoveryProcessTests` launches `RecoveryIntegrationFixture` in separate processes. One exits after receipt persistence but before host commit. A second exits after host commit but before acknowledgement. Later processes retrieve/acknowledge without another generation, and the host commit count remains one. These are actual process exits, not merely new actors sharing an in-memory store.
