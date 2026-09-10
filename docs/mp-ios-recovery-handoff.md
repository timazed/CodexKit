# Prompt for mp-ios / Pocket POTUS

Integrate the CodexKit structured recovery API into Pocket POTUS's unfinished Day 2 preparation path. Read AGENTS.md and inspect the existing stage persistence, retry loop, cancellation, account handling, and structured decoding first. Update to CodexKit `v2.0.0-alpha.30`, which includes `prepareStructuredRecovery` and `sendRecovering`; alpha.29 does not include them. Update the dependency and lockfile together.

The TestFlight message “The connection ended before the response finished” could mean premature Responses EOF, networkConnectionLost, or timedOut. The underlying device error is still unconfirmed. Do not claim this incident is diagnosed or that a provider response can be resumed.

Use only client-managed state and ephemeral, one-shot structured requests. For each unfinished logical gameplay operation, prepare one recovery handle and persist it in app state before sending. After relaunch, reuse that handle. Never create another handle merely because recovery reports unavailable, expired, cancelled, failed, or exhausted state.

Call `sendRecovering` with the host's existing three-attempt budget. Its required `authorizeAttempt` callback runs before every generation POST, including authentication reissues. Atomically reserve by the SDK's unique attempt ID, use the saved attempt number, prevent concurrent retry taps, and remove nested retry loops that reset the budget. The callback may wait/back off and can inspect the previous failure. Returning false must stop transmission. Preserve cancellation and account-change behavior; do not automatically start replacement work under a different account.

The SDK disables tools for this API. Audit whether Day 2 preparation currently needs tools before integrating it. Do not move tool effects into an untracked outer retry loop. Provider mechanics and the local receipt store belong in CodexKit.

Store receipts in Application Support. Commit a gameplay stage only after a complete validated result, make that commit idempotent by recovery operation ID, then acknowledge the SDK receipt. Preserve all already-completed gameplay stages. A crash after SDK receipt persistence but before the gameplay commit can return the same saved result after relaunch with no generation request. A terminal event that never reached the SDK still requires an explicitly authorized replacement generation.

Add privacy-preserving diagnostics for stage ID, operation/attempt IDs, SDK version, saved attempt count, error code, `AgentRuntimeError.interruption`, and cancellation/lifecycle state. Do not log credentials, account identifiers, prompts, raw JSON, or receipt contents. Responses transport errors now expose their URL error domain/code inside typed interruption metadata rather than as raw URLError.

Test drops before output, mid-response, and before the terminal event; budget exhaustion; cancellation; concurrent retry taps; account changes; invalid output; and process relaunch after receipt persistence but before gameplay commit. Assert preserved stages, no partial commit, no duplicated effects, and zero generation calls when returning a saved completion. Avoid a hard generation deadline; the recovery API has none, and transport idle timeout/background expiration remain distinct.

Read [the SDK guide](structured-request-recovery.md) for the exact API and boundaries. Report implementation changes, tests, and remaining device diagnostics needed. If the app already performed equivalent bounded replacement attempts, distinguish that existing behavior from the new benefits of persistent budget/cancellation, account binding, and saved completed results.
