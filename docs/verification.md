# Runtime verification

[Documentation index](index.md) · [SDK integration](sdk-integration.md)

The latest published SDK is alpha.30; see its [release verification report](release-readiness-alpha30-2026-09-10.md). The streamlined workflows below replace repeated candidate/main/tag builds with exact-commit verification reuse. Historical reports retain the checks that ran for their original revisions.

The 8 September deep-audit regressions are in `DeepAuditRegressionTests`, `CompactionTransportTests`, `PreparationCancellationTests`, and `OneShotValidationTests`. They cover conflicting/stale compaction, database reopen behavior, request and response image references, bounded compact bodies, session recovery, network cancellation, startup cancellation before/during persistence, strict root policy fields, and one-shot schema/Swift decoding before commit.

On 8 September 2026, the final package suite executed 527 tests with warnings treated as errors: 521 passed, six opt-in checks skipped, zero failures. The optimized release build and all 29 selected performance/SDK/storage checks passed separately, also with warnings treated as errors; the latter included 40 concurrency waves per disk adapter. The signed iOS 26.5 simulator verifier passed SQLite/Realm completion, reopening, and cancellation again after the cursor and Realm compiler fixes. The source guard passed all 211 production files (208 Swift files and three scripts). [Hosted CI](https://github.com/timazed/CodexKit/actions/runs/34195469609) also passed all four jobs on code revision `d75130c`, including macOS 14 / Swift 6.1.3 and actual iOS 17.0.1 execution. See [release readiness](release-readiness-2026-09-08.md) for evidence and remaining gates. Both explicitly enabled live tests skipped because no current SDK/demo session was saved on this Mac.

## Deterministic tests

Run `swift test` for the package suite. Most backend tests use a local URLProtocol fixture; database tests exercise in-memory, file, SQLite, and Realm stores. The optional live-provider and performance workloads skip during ordinary runs.

`ExternalSessionDiscoveryTests`, `ExternalSessionLifecycleTests`, and `ExternalSessionRuntimeTests` cover read-only discovery, safe failures, binding, rotation, renewal coalescing/timeouts, disconnect, and bounded recovery without replaying tools. `ScopedStorageTests` checks account-directory isolation and rejects host database files. These tests use synthetic credentials and local backend fixtures.

Run `python3 Scripts/verify_local_codex_session.py` for a signed native file/Keychain/auto discovery probe with disposable synthetic records. `python3 Scripts/verify_macos_demo.py` defaults to a short signed-app smoke check. Add `--mode full` for the full authentication, tools, memory, compaction, persistence, and dropped-connection scenarios. Both modes verify completed-result recovery in a second app process. The [macOS walkthrough](../DemoApp/README.md#macos-demo) documents separate, explicit live-session checks.

The audit follow-up adds coverage for provider injection, host session management, cross-account recovery cancellation, execution readiness before event consumption, ephemeral cancellation, observation cleanup/overflow, typed HTTP details, server retry delays, bounded image error ingestion, and the earlier auth/history/tool/streaming regressions.

`ToolResultValidationTests` additionally covers unsolicited, duplicate, mismatched, and late submissions, cancellation while waiting for out-of-order tool results, and persistence of executor identity errors under the original invocation.

`RealmHistoryWindowTests` compares every returned record, cursor, and paging flag with the reference store across both directions, sequence/date ordering, filters, redactions, compaction markers, restored histories, and sequence boundaries. `HistoryCursorEncodingTests` verifies canonical encoding for both cursor versions and compatibility with previously issued unsorted encodings. The compaction tests also cover exact response limits across 64 KiB buffers, interrupted downloads, and nested image-reference validation.

`StorageLockCancellationTests` and `StorageQueueCancellationTests` cover cancelled lock acquisition, an external lock owner, descriptor cleanup, partially acquired exclusive leases, queue ordering after cancellation, shared preparation, and runtime startup while file/SQLite/Realm storage is contended. Cancellation leaves commits already underway protected; runtime-owned pending writes and interruption records drain in order. The [lock audit](storage-lock-audit-2026-09-08.md) retains the original failing reproduction.

`RuntimeConcurrencyStressTests` exercises file, SQLite, and Realm stores with two runtimes owning three distinct threads each in the same store. Each wave gates six backend operations until they all overlap with a fresh database reader. Worker roles rotate through three completed turns, one interrupted turn, one completed compaction, and one cancelled compaction. Conflicting operations on the same thread must report busy. Capacity-one queues, slow consumers, and shared image bytes exercise event delivery and attachment reconciliation.

After every wave, a separately reopened store is compared with an independent expected transcript: message order/content, unique message IDs and history sequences, image bytes, streamed text, interruption records, compaction generations/markers, and idle status must agree. Activation must retain the latest completed reply; interrupted input must remain in the durable transcript. Both owning runtimes are replaced every four waves and at the end, then their threads are reactivated. The default six waves cover every role on every worker and continue work after reopening. `CODEXKIT_STRESS_ROUNDS` accepts 1–200; malformed or out-of-range values fail. A 30-second wave watchdog releases test gates with an error, and backend producer tasks are joined before cleanup. The workload uses temporary stores and a local custom backend; it does not contact a live provider or simulate abrupt process death.

Run the longer concurrency workload alone with:

```sh
CODEXKIT_STRESS_ROUNDS=40 swift test -c release -Xswiftc -warnings-as-errors \
  --filter RuntimeConcurrencyStressTests
```

`ExecutionCleanupTests` checks backend interruption after readiness when initial runtime events have not been consumed, including explicit cancellation for plain/structured executions, deadlines, and cleanup on ordinary completion.

`DefinitionValidationTests` covers malformed skill policy fields, UTF-8 byte-order marks, empty allowlists, optional policies, plain text, bounded file/remote loading, misleading response lengths, and cancellation. `ToolOutputFidelityTests` verifies every text block reaches the next provider request, fallback reply, and effective context, including after reopening SQLite and Realm stores; image cases cover HTTP errors, HTML, truncated bodies, actual image-type detection, byte preservation, size limits, and cancellation.

## Optimized pipeline checks

```sh
CODEXKIT_RUN_PERFORMANCE_TESTS=1 CODEXKIT_STRESS_ROUNDS=40 \
  swift test -c release -Xswiftc -warnings-as-errors \
  --filter 'RealisticPerformanceTests|RuntimeSystemBenchmarkTests|RuntimePerformanceTests|SDKDesignTests|StorageQueueCancellationTests|StorageLockCancellationTests|RuntimeConcurrencyStressTests'
```

This measures image-heavy request construction/compaction, large SQLite/Realm history paging and activation, cancellation with slow consumers, parsing, and a complete stubbed-HTTP-to-SQLite pipeline. It also checks SDK ownership, storage cancellation, and 720 overlapping lifecycle operations across the three disk adapters under optimization. Benchmarks report process CPU time and peak resident memory without asserting machine-dependent timing thresholds. See the [latest workload measurements](performance-2026-09-08.md) and [earlier parser/pipeline results](performance-2026-09-07.md).

## Live-provider checks on macOS

```sh
CODEXKIT_RUN_LIVE_TESTS=1 swift test --filter LiveProviderTests
```

These tests look for a current session in the known SDK (`CodexKit.ChatGPTSession` / `default`) and demo (`AssistantRuntimeDemoApp.ChatGPTSession` / `AssistantRuntimeDemoApp`) Keychain entries on this Mac. An explicit `CODEXKIT_LIVE_KEYCHAIN_SERVICE` or `CODEXKIT_LIVE_KEYCHAIN_ACCOUNT` override restricts lookup to the supplied entry. A missing/expired session skips the checks; no test initiates sign-in or refresh or prints credentials.

The first test sends a small plain request and a structured request with an in-memory transcript. The image test uses a generated red PNG and a random marker, then compacts remotely, reopens a temporary SQLite/Realm store, and asks the model to recall the marker and color. It exercises client-managed and server-managed state with each adapter. Passing requires retaining context; the later prompt/schema does not reveal the marker or color. Temporary database files are removed after the test. Tools, web search, and image generation remain disabled. Requests have one model pass and a 60-second runtime deadline; compact requests use a 45-second timeout. The image test permits up to 8 MiB per response.

A complete run uses up to 14 small provider requests, including four remote compactions. A session saved on an iPhone or simulator is not automatically available to a test process on the Mac. The demo's separate device verifier checks plain/structured completion; the full image/compaction matrix currently runs through the Mac package tests. A skipped or inaccessible-session check is not evidence of live-provider compatibility.

## CI and release promotion

CI has one canonical push verification for `main` and `codex/**`. Same-repository `codex/**` PRs wait for passing branch evidence instead of duplicating the builds; a pending, failed, or missing branch result cannot make the PR gate green. Other PRs verify GitHub's merge revision. A merge producing a different SHA must pass its own main verification before release. Superseded development runs are cancelled; main and scheduled runs are not interrupted by newer revisions.

The plan job runs the cheap source-size guard and Python harness/gate tests. If a trusted CI run already passed every required job for the exact SHA, compilation and app execution are skipped and the original evidence URL is retained. Reuse-only runs cannot certify themselves. Fork/PR runs, different commits/workflows, missing or skipped mandatory jobs, and a later completed failure cannot serve as release evidence. An API error causes fresh CI verification; the same error blocks release publication.

Fresh verification runs these lanes in parallel:

| Lane | Checks |
| --- | --- |
| SDK (current) | Full Debug suite on the current compiler. |
| SDK (optimized) | Optimized correctness/recovery tests with six concurrency rounds, running alongside Debug tests. Its test target depends on all four library targets; no separate overlapping release-build command. |
| SDK (minimum) | Full Debug suite on macOS 14 / Swift 6.1.3. Optimized checks run on the current compiler. |
| Demo (iOS) | Signed current-runtime build, SQLite/Realm completion/reopen/cancellation, saved structured result, and retrieval in a second app process. |
| Demo (macOS) | Signed app startup, controlled chat, conversation restoration, cancellation, saved structured result, and retrieval in a second app process. |
| Build iOS 17 verifier → Demo (iOS 17) | Xcode 16.4 produces a signed universal simulator app once; macOS 14 executes it on iOS 17.0.1 without rebuilding. |

`Verification gate v1` requires all mandatory lanes to pass. Relevant storage/concurrency changes select 40 optimized concurrency rounds instead of six. The same optimized job then runs larger image/storage benchmarks with `--skip-build`, using the test bundle it just successfully compiled; no cache-only or foreign test binary is executed without a build first. Relevant demo/authentication/recovery changes select full demo mode. `Scripts/ci_plan.py` defines the path rules. A daily 18:00 UTC run and manual dispatch with `extended: true` force fresh, comprehensive checks even if the commit already passed. No live accounts or model calls are enabled by CI.

Build caches are partitioned by lane, actual OS/architecture/Xcode/Swift versions, and dependency lockfiles. Each identity keeps one incremental build baseline instead of a multi-gigabyte snapshot for every commit. SwiftPM/Xcode must still rebuild changed inputs and tests always execute; a cache hit is never a passing test. GitHub's branch cache scopes still apply: new branches can use default-branch caches, while a cache made only on another feature branch is not shared automatically. Scheduled/manual comprehensive verification on main refreshes default-branch baselines when dependency or toolchain identities change. Dependency versions are locked during SwiftPM and Xcode builds. Current-runtime iOS builds compile only the host architecture; the portable iOS 17 artifact retains both architectures.

Release publication runs on Ubuntu, with no Swift build or simulator. It resolves the tag to a commit reachable from `origin/main`, validates the changelog entry, and checks GitHub CI evidence. If no verification exists, it can dispatch one CI run for the tag; if a run is already active, it waits for that run. It never automatically retries failed verification. The wait is bounded to eight minutes and an unfinished run remains a failure to publish. Once verification finishes, manual release dispatch can retry publication without rebuilding. The publish job checks the tag still resolves to the verified SHA and uses only the validated changelog notes.

The release gate uses `actions: write` only to dispatch missing verification; it has read-only contents permission. Only the publisher has `contents: write`. Old tags whose workflows predate the new evidence policy cannot bypass it using an older passing job layout. They need compatible verification rather than the previous compilation-only legacy fallback.

### Timing goals and evidence

Publication of an already verified commit should take 1–2 minutes, subject to GitHub scheduling. Fresh routine CI targets less than ten minutes with compatible caches. Cold caches, extended workloads, and hosted-runner queues are measured separately; the timeout is not a mechanism for declaring unfinished tests successful. Mac build lanes retain a 15-minute failure limit, while the release evidence wait stays within eight minutes.

`Scripts/ci_timed.py` records SDK command duration and exit status. Demo `timings.json` files separate build, simulator setup, and app execution/relaunch. Each timing is also added to the job summary. Artifacts retain logs, both process reports, and timings for 14 days (`sdk-current`, `sdk-minimum`, `sdk-optimized`, `demo-iOS`, `demo-macOS`, `minimum-simulator-build`, `minimum-simulator-verification`). The portable app and release-note transfer artifacts last one day.

[The streamlining evidence](verification-streamlining.md) distinguishes local measurements from hosted results and records the original alpha.30 baseline.

## Local demo verification

```sh
python3 Scripts/check_source_size.py
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests/Verification
python3 Scripts/verify_ios_simulator.py --mode smoke
python3 Scripts/verify_macos_demo.py --mode smoke
```

Both harnesses default to `smoke`; use `--mode full` for the retained extensive app scenarios. SDK tests retain the detailed transport, budget, validation, and tool-side-effect permutations. Neither smoke nor full mode uses live credentials. The iOS script creates only its own temporary simulator and removes it on success/failure. A matching run ID, mode, and completed report are mandatory. Both harnesses launch a second app process and require a fresh successful receipt-recovery report; a first-process report cannot satisfy the reopen check.

Use `--output-dir` to choose the iOS report directory, `--derived-data` to choose its build directory, or `--runtime 17.0.1` to require a specific installed runtime. `--build-only` produces a portable signed app without simulator access. `--app /absolute/path/CodexKitIOSDemo.app` runs a prebuilt app without compilation. The macOS `--skip-build` option similarly runs an existing signed build.

Cold CoreSimulator runtime discovery retries only timed-out reads within 120 seconds. The iOS container lookup remains separately bounded: timed-out reads are retried within 180 seconds without reinstalling or relaunching. Failed commands, invalid paths, stale reports, and failed assertions are not retried. App report waits are also bounded to 180 seconds. The source guard enforces 600 physical lines per production Swift file and repository verification script.

## iOS simulator and physical device

Build and run the demo normally for a UI startup check. For automated checks, add `--verify-runtime` to the demo's Run arguments in Xcode. The argument is recognized in Debug builds only and leaves ordinary launches unchanged.

Use a signed app for runtime verification, including on the simulator. The CI script supplies ad-hoc signing; unsigned simulator builds omit the application identity needed by Keychain. For a local simulator build, use:

```sh
xcodebuild -project DemoApp/CodexKitDemo.xcodeproj \
  -scheme CodexKitIOSDemo \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- build
```

This uses local ad-hoc signing. Install that build and launch it with `--verify-runtime`, or run the scheme through Xcode with signing enabled.

The verifier creates temporary, uniquely identified test threads in each managed SQLite/Realm adapter, verifies plain/structured completion, reopens each database, checks cancellation, and deletes those test threads. Unless `--verify-local-only` is supplied, it also attempts the two plain/structured live-provider checks using the demo's existing current session, with ephemeral requests and an in-memory transcript. It never initiates sign-in or refresh. Existing conversations are not used as test input.

Results are written to `Documents/CodexKitVerification.json` in the demo's app container. Retrieve that report using Xcode's container download or the simulator/device tools. It includes timestamps, a run ID, individual `sqlite` / `realm` outcomes, and aggregate `localAdapters` / `liveProvider` outcomes; errors contain codes rather than credentials or provider response content. `skipped: no_current_session` or a Keychain failure requires signing in or correcting the host's Keychain/signing setup before retrying live checks.

On 7 September 2026, before the final cancellation cleanup fix, a signed build installed and launched on the connected iPhone. Its verification report passed the local SQLite, Realm, structured-completion, and cancellation checks. The locally signed iOS 18.6 simulator build passed the same checks and resolved the earlier `keychain_read_failed` result from the unsigned build. The signed simulator build was repeated successfully after the cleanup and definition/tool-output fixes. Both runtime reports returned `skipped: no_current_session` for live-provider checks; the documented Mac SDK and demo Keychain entries also had no current session. Live-provider compatibility still requires sign-in and a completed live check. No physical-device energy measurement has been claimed.
