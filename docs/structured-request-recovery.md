# Recoverable structured requests

This API supports **local completed-result recovery and explicit replacement generations**. It does not retrieve a remote response or resume a disconnected provider stream. It keeps `.clientManaged` and `store: false`.

Use it for ephemeral, one-shot structured requests such as Pocket POTUS preparation. The operation freezes its request, model configuration, resolved instructions, response schema, endpoint, and account binding in an opt-in local store. All registered and built-in tools are disabled for this path; unexpected tool activity fails without executing host tools or starting a replacement.

## Small Pocket POTUS integration

```swift
let receipts = AgentStructuredRecoveryStore(
    directory: applicationSupport.appendingPathComponent("PreparationRequests")
)

// Create once per unfinished gameplay operation, then persist this handle in app state.
let handle = try await runtime.prepareStructuredRecovery(
    Request(text: preparationPrompt, executionMode: .ephemeral),
    in: threadID, response: DayPreparation.self,
    store: receipts, maximumAttempts: 3
)
try await gameplay.saveRecoveryHandle(handle, for: stageID)

// After relaunch, use the saved handle instead of preparing another operation.
let result = try await runtime.sendRecovering(
    handle, response: DayPreparation.self, store: receipts
) { attempt in
    // Atomically reserve the app's existing budget. This runs before every generation
    // POST, including authentication reissues. Wait/back off here if appropriate.
    try await gameplay.reserveAttempt(attempt.id, for: stageID, limit: 3)
}
try await gameplay.commitValidatedStage(result, operationID: handle.id)
try await runtime.acknowledgeStructuredRecovery(handle, store: receipts)
```

The `gameplay` methods are host-owned examples. Persist the handle before sending, keep completed stages, make the gameplay commit idempotent by operation ID, and do not create a new handle when an old one is missing, expired, cancelled, or exhausted. Only acknowledge after the gameplay commit. If the process stops between those two operations, the same result is available again; the app's idempotent commit prevents a duplicated gameplay effect.

There is no generation deadline in this API. It does not use the ordinary runtime turn's `maximumDuration`; backend response-size, item, model-pass, and transport idle limits still apply. Background expiration and explicit task cancellation stop work. This API does not publish partial output, append conversation history, run memory capture, execute tools, or update gameplay state.

## Attempt authorization and persistence

Calling `prepareStructuredRecovery` makes no generation request. `sendRecovering` first checks for a saved completion and validates its JSON schema and Swift decoding again. This path makes **zero generation POSTs and zero authorization callbacks**. A completed result is written atomically before returning to the caller.

Otherwise, the required host callback authorizes each new generation attempt. Each callback contains an operation ID, a fresh HTTP attempt ID, a persisted attempt number, the maximum, a reason, and available previous failure/response/cursor metadata. The attempt ID becomes `x-client-request-id`. The original host correlation ID remains attached to the frozen request. Replacement POSTs contain the same canonical request body, but start new provider generations.

SDK transient retries are disabled inside this API even if the backend normally retries. Authentication renewal may reissue a rejected POST, but that reissue must pass the same callback and persisted limit. Token renewal itself is not a model-generation attempt. Do not wrap this API in an additional retry loop that creates new handles or resets the budget.

After authorization, the SDK saves the consumed slot before transmission. A crash can therefore consume an unused slot, but cannot reset the budget. The host should also durably reserve by attempt ID before returning `true`; failure between the two saves is conservative. Returning `false` sends no request. The host controls waiting/backoff and can examine `previousFailure.http.retryAfter`.

Local locks reject concurrent opens of the same operation, including separate runtimes and processes. Account/source binding is checked before reading a result, before every generation POST, after host authorization, while consuming output, and before saving completion. Account changes do not rebind a saved request. An active sign-out interrupts the runtime's recovery execution.

## Outcomes

| Outcome | Behavior |
| --- | --- |
| Connection loss, timeout, or premature EOF | Discard that attempt's partial output. Request host authorization for a replacement if budget remains. |
| Transient HTTP rejection | Request authorization for a replacement within the same budget. |
| Provider `response.failed` or `response.incomplete` | Save a permanent failure and return it. Reopening does not restart it. |
| Invalid structured output | Save a failure; never return or cache a partial/unvalidated result. |
| Missing/corrupt/expired state | Return a typed error; no fallback generation. |
| Host denies an attempt | Return `attemptNotAuthorized`; retain the budget and prior failure. |
| Last permitted attempt fails | Return that failure and retain the exhausted count. Reopening reports `attemptsExhausted` without authorizing another POST. |
| Explicit cancellation | Save cancellation; reopening that operation cannot restart it. |
| Process stops without recording an outcome | Retain the consumed budget and last saved response ID/cursor; any replacement still needs host authorization. |
| SDK saved completion; app did not acknowledge | Return and validate the local receipt, including after a process restart. |

`structuredRecoveryStatus` reads account-bound local status while an operation is idle. `cancelStructuredRecovery` permanently cancels an idle saved operation; cancel the Swift task for active work. `acknowledgeStructuredRecovery` deletes a completed record after host commit. Expiry controls access to local recovery state and permission to start another attempt, not a running generation's duration.

## Interruption diagnostics and duplicate events

Responses errors now include `AgentRuntimeError.interruption`: outcome, host correlation, HTTP attempt ID, provider response ID, last observed sequence number, output/tool activity, provider completion, and transport domain/code. Network URL errors from this backend are wrapped in `AgentRuntimeError`; callers previously catching only `URLError` should read `interruption.transportErrorCode`. Existing cancellation remains `CancellationError`. The metadata contains diagnostics, not a resumable remote handle.

Numbered SSE events already consumed in the same ordered stream are ignored when repeated. Repeated host function-call IDs within a turn do not execute again; conflicting arguments for an existing ID fail. This is not an exactly-once tool guarantee across requests or app restarts. The recovery API's tool prohibition is what makes replacement safe without a durable tool-effect ledger.

## Limits and evidence

The authenticated endpoint rejected `store: true` and `background: true`. Recovery GETs encountered Cloudflare challenges, leaving origin-level support unverified. See the [endpoint investigation](response-recovery-investigation-2026-09-10.md). No new endpoint capability is assumed here.

A lost terminal event that never reaches the SDK cannot be recovered from this store. A valid-looking JSON output item is not proof of provider completion. That case needs a newly authorized generation. There is also a crash window between receiving completion and atomically saving its validated receipt; a receipt can only recover a completed result that was actually saved.

If an app already performs equivalent bounded, tool-free replacement attempts, moving that loop into this SDK API does not improve the success probability of those attempts. The additional capabilities are persistent attempt accounting and cancellation, account-bound frozen requests, budgeted authentication reissues, interruption diagnostics, duplicate-event protection, and retrieval of completed local receipts.

The store contains model input, resolved instructions, account binding, and completed JSON. It is explicit opt-in, uses private file permissions and Apple file protection, and never persists access/refresh tokens. Keep it in Application Support and apply the host's data-retention policy. The handle itself contains only an operation UUID. Do not log the store contents or raw output as diagnostics.

Both demo verification harnesses run an offline transport against the real SDK backend, compare single-send interruption with authorized replacement, enforce the three-attempt limit, cancel after output, and launch a second app process to retrieve a saved result with zero generation requests. These checks establish client behavior, not remote stream resumption or a diagnosis of the original TestFlight incident.
