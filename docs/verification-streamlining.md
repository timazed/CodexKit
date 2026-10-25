# Verification and release streamlining

This change affects repository verification and the Debug demo harnesses. It changes no production SDK API, recovery policy, or gameplay integration. It does not publish a new SDK version by itself.

## Current policy (26 October 2026)

Routine PR/main verification now runs current Debug and optimized SDK checks (two macOS jobs). Minimum-compiler, signed demo, iOS 17, remote-demo integration, and longer stress workloads run nightly or through manual `extended: true` dispatch. Feature-branch pushes no longer duplicate pull-request workflows. Planning is local and deterministic, with no API-based reuse or branch-proof polling.

Release evidence still requires the complete original matrix for the tagged SHA. A routine green gate is insufficient; the release workflow requests comprehensive verification when needed and allows up to 40 minutes for it to finish. The existing gate check name is retained for branch protection. See [the current policy](verification.md#ci-and-release-promotion).

The [25 October scheduled failure](https://github.com/timazed/CodexKit/actions/runs/40230402120) occurred when CoreSimulator timed out terminating the demo app; SDK jobs passed. Moving simulator-dependent work out of routine CI reduces its impact on ordinary changes, but does not claim to fix CoreSimulator itself. Demo/platform regressions now require comprehensive verification to detect. Hosted timings for this revision have not yet been measured.

Compatibility execution has moved to macOS 15 / Xcode 16.4, retaining Swift 6.1.3 and explicitly installing iOS 17.5. macOS 14 and iOS 17.0.1 runtime execution are no longer covered by hosted CI; deployment targets remain unchanged.

The sections below record the earlier alpha.30 implementation and measurements; their all-lanes-per-change and PR-delegation policy has been superseded.

## Measured baseline

Alpha.30 commit `2dd82ad5f80e97debc0999c43dba81633abb5515` ran the current-host pipeline three times:

| Workflow | Current-host job |
| --- | --- |
| [Candidate CI](https://github.com/timazed/CodexKit/actions/runs/34487061834) | 44m 17s |
| [Main CI](https://github.com/timazed/CodexKit/actions/runs/34492132883) | 16m 38s |
| [Tag verification](https://github.com/timazed/CodexKit/actions/runs/34492132713) | 38m 35s |

The main and tag jobs overlapped; their durations must not be added as sequential waiting. Candidate push to publication was approximately 85 minutes. All jobs together consumed about 143 runner-minutes. The publisher itself took eight seconds. The tag's iOS and macOS build/verifier steps consumed 13m 26s and 4m 35s respectively. These combined timings do not attribute all that time to test assertions.

## Implementation

- A release reuses complete, exact-SHA CI evidence instead of rebuilding packages and demos. Missing verification can be dispatched once; failed verification is not automatically retried. Pending/failed/skipped checks never become successful by timeout.
- Main reuses original branch evidence when its commit SHA is identical. A merge producing another SHA requires fresh verification. Same-repository Codex PRs delegate to their existing branch checks; other PRs verify the merge revision.
- SDK compatibility, current Debug tests, optimized tests, signed iOS/macOS demos, and the portable iOS 17 build execute in parallel. The iOS 17 runtime step reuses its signed artifact without recompilation.
- Dependency and build caches include toolchain/platform and lockfile identities. One incremental baseline per identity avoids duplicating gigabytes for each commit. Every build/test still executes after cache restoration. The redundant standalone optimized build was folded into optimized tests, which compile all four library dependencies.
- Both demos default to smoke mode. Cancellation and second-process result retrieval remain mandatory. Full scenarios remain available with `--mode full`, are selected for relevant changes, and run on the daily comprehensive check.
- Ordinary optimized concurrency uses six rounds. Relevant changes, manual extended dispatch, and scheduled verification select 40 rounds in the same job. Larger benchmarks reuse that job’s freshly built test bundle, eliminating a second cache-restore/build cycle.
- Reports record build/setup/execution separately. The release gate and planner have controlled tests for missing, foreign, incomplete, failed, stale, and reused evidence.

See [verification instructions](verification.md#ci-and-release-promotion) for commands, cache boundaries, artifact names, permissions, and the release policy.

## Local verification

Measured on the development Mac with existing compatible build directories; these are not cold-cache hosted timings:

| Check | Result |
| --- | --- |
| Signed macOS smoke | Build 11.170s; initial app 0.924s; second process 0.148s; passed |
| Signed iOS smoke | Build 10.138s; simulator setup 20.000s; execution/relaunch 2.851s; passed |
| Retained full macOS/iOS modes | Both passed using the prebuilt signed apps; full assertions and second-process receipt recovery retained |
| Full SDK Debug suite with locked versions | 593 tests, six expected opt-in skips, zero failures; build and tests 186.420s |
| Short optimized lane with locked versions | 55 tests passed; build and tests 86.028s, of which test execution was 7.802s |
| Extended optimized bundle reuse | 55 tests passed at 40 stress rounds; all four larger benchmarks passed using the same built test bundle |
| Gate/planner/demo-harness tests | 38 tests passed, including dispatch-once, timeout, stale/foreign proof, failed-verification rejection, cold simulator discovery, and PR delegation |
| Workflow validation | Official actionlint v1.7.12 passed |
| Source-size and whitespace guards | Passed |

The initial target is 1–2 minutes to publish an already verified commit and less than ten minutes for fresh routine CI with compatible caches. Cold-cache and extended runs must be measured separately. Hosted timing validation is recorded below as it completes; the timing target is not yet a measured guarantee.

The [first cold hosted run](https://github.com/timazed/CodexKit/actions/runs/34501275170) exposed a 60-second CoreSimulator runtime-listing timeout before the current iOS app build began. The harness now retries this read within a shared 120-second bound; malformed responses, command failures, build errors, and assertions still fail immediately. This run cannot certify the candidate because the iOS job failed. Other lane results remain useful timing evidence.

The same cold run showed that keeping Debug and optimized compilation in one SDK job exceeded ten minutes. Those configurations now run as independent mandatory lanes. The full suite, optimized coverage, and both compiler profiles remain required.

The [second candidate](https://github.com/timazed/CodexKit/actions/runs/34502998277) passed every mandatory lane and extended stress. The separate stress job took another 12m 03s after optimized correctness completed, showing avoidable setup and recompilation; the final workflow selects the round count in the optimized lane and runs only the remaining benchmark cases from the freshly built bundle.
