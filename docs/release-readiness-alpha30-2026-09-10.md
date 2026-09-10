# Alpha.30 structured recovery verification

This candidate adds client reliability features to alpha.29: durable completed-result receipts, frozen account-bound structured requests, persistent attempt accounting, host authorization before generation POSTs (including authentication reissues), typed interruption diagnostics, and duplicate-event protection. It does **not** add remote result retrieval or stream resumption.

The implementation is limited to ephemeral, one-shot structured requests with tools disabled. The host retains gameplay persistence and authorization of replacement attempts. See [integration and limitations](structured-request-recovery.md) and the [mp-ios handoff](mp-ios-recovery-handoff.md).

## Measured demo behavior

The real Responses backend ran with a controlled offline transport inside both signed demo apps. The iOS harness used iOS 26.5 on a disposable iPhone 17 Pro simulator. Both harnesses terminated the first app process after saving an unacknowledged completion and launched a second process to retrieve it.

| Scenario | Measured result on both platforms |
| --- | --- |
| Drop before output | Existing single send with SDK retries disabled fails after 1 POST; recovery succeeds after 2 authorized POSTs. |
| Drop mid-response | Same result: 1 failed single send versus a complete validated result after 2 authorized POSTs. Partial output is discarded. |
| Provider completion not delivered to client | A valid output item without the terminal event is rejected; an authorized replacement completes after 2 POSTs. |
| Repeated drops | Stops after exactly 3 POSTs. |
| Cancellation after output | Saves cancellation and stops after exactly 1 POST. |
| Saved completion, app restarted before acknowledgement | A new app process returns the validated result with 0 POSTs and 0 attempt authorizations. |

The comparison is against the existing **single-send API with retries disabled**, not against an app that already implements an equivalent bounded replacement loop. Such an app already has the replacement success behavior. Local completed-result retrieval and persistent accounting/cancellation are additional capabilities. A completion that was never received and saved still cannot be retrieved.

[Recorded demo evidence](structured-recovery-demo-evidence-2026-09-10.json) contains synthetic fixture results only. No live model requests, credentials, or end-user prompts were used for these verification runs. The original TestFlight error remains unconfirmed without device logs.

## Local verification

| Check | Result | Evidence |
| --- | --- | --- |
| Full package suite, warnings as errors | 593 tests, 6 expected opt-in skips, 0 failures | `.build/recovery-full-tests.log` |
| Optimized library build, warnings as errors | All four library products passed | `.build/recovery-release-build.log` |
| Recovery and transport tests in Release configuration | 30 tests passed, 0 failures | `.build/recovery-optimized-tests.log` |
| New recovery tests | 18 passed, including raw network loss/timeout, 401 budget/denial, account changes/credential rotation, cancellation, concurrent open, tool rejection, invalid JSON, corrupt receipt, and cold interrupted state | `.build/recovery-isolation-tests.log`, full suite |
| Signed macOS demo | 31 checks plus second-process receipt recovery passed | `.build/recovery-macos-demo-final.log` |
| Signed iOS demo | Adapter checks, controlled recovery comparisons, and second-process retrieval passed | `.build/recovery-ios-verification-final/` |
| Python simulator harness tests | 11 passed | `.build/recovery-harness-tests.log` |
| Core/UI API comparison with alpha.29 | No removed declarations or changed existing requirements | `.build/recovery-api-review/` |
| Source-size and whitespace checks | 242 production files at or below 600 lines; clean diff check | `Scripts/check_source_size.py`, `git diff --check` |

An earlier suite run exposed a timing-sensitive Realm corruption fixture: it mutated storage through a second Realm instance, then read through a cached actor-bound snapshot before notification advancement. The test now opens a fresh reader after corruption to validate persisted data deterministically. Realm production code was not changed. The final full suite passed in approximately 149 seconds.

Responses URL errors are now wrapped in `AgentRuntimeError` with `interruption.transportErrorDomain`/`transportErrorCode`. The previous runtime-error initializer is retained, and old Codable errors remain readable. Hosts that catch only `URLError` need to update their mapping. Ordinary `send` keeps its existing conservative replay boundary.

## Publication gate

The user required demonstrable improvement in the demo apps before release. Those local demonstrations and the optimized library build passed.

[Candidate CI 34487061834](https://github.com/timazed/CodexKit/actions/runs/34487061834) passed all four jobs on commit `2dd82ad5f80e97debc0999c43dba81633abb5515`: minimum/current verification, the Swift 6.1 iOS verifier build, and the iOS 17 runtime verifier. Current-host verification included package tests, optimized builds and stress checks, and both signed demo harnesses with second-process receipt retrieval.

The immutable tag `v2.0.0-alpha.30` points to that exact candidate commit. [Release verification 34492132713](https://github.com/timazed/CodexKit/actions/runs/34492132713) passed both jobs: exact-tag verification (including the full package suite, optimized build/stress checks, and both demo harnesses) and publication.

[The GitHub prerelease](https://github.com/timazed/CodexKit/releases/tag/v2.0.0-alpha.30) was published at **2026-09-10 15:33:19 UTC**. The public release record confirms `draft: false` and `prerelease: true`. This publication record is a subsequent documentation-only update; the tested release tag remains unchanged.
