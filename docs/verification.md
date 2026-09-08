# Runtime verification

[Documentation index](index.md) · [SDK integration](sdk-integration.md)

The 8 September deep-audit regressions are in `DeepAuditRegressionTests`, `CompactionTransportTests`, `PreparationCancellationTests`, and `OneShotValidationTests`. They cover conflicting/stale compaction, database reopen behavior, request and response image references, bounded compact bodies, session recovery, network cancellation, startup cancellation before/during persistence, strict root policy fields, and one-shot schema/Swift decoding before commit.

On 8 September 2026, the final package suite executed 524 tests with warnings treated as errors: 518 passed, six opt-in checks skipped, zero failures. The optimized release build and all 29 selected performance/SDK/storage checks passed separately, also with warnings treated as errors; the latter included 40 concurrency waves per disk adapter. The signed iOS 26.5 simulator verifier passed SQLite/Realm completion, reopening, and cancellation after the storage-lock fix; the later concurrency/CI additions change no production Swift code. The source guard passed all 210 production files (207 Swift files and three scripts). See [release readiness](release-readiness-2026-09-08.md) for evidence and remaining gates. Both explicitly enabled live tests skipped because no current SDK/demo session was saved on this Mac.

## Deterministic tests

Run `swift test` for the package suite. Most backend tests use a local URLProtocol fixture; database tests exercise in-memory, file, SQLite, and Realm stores. The optional live-provider and performance workloads skip during ordinary runs.

The audit follow-up adds coverage for provider injection, host session management, cross-account recovery cancellation, execution readiness before event consumption, ephemeral cancellation, observation cleanup/overflow, typed HTTP details, server retry delays, bounded image error ingestion, and the earlier auth/history/tool/streaming regressions.

`ToolResultValidationTests` additionally covers unsolicited, duplicate, mismatched, and late submissions, cancellation while waiting for out-of-order tool results, and persistence of executor identity errors under the original invocation.

`RealmHistoryWindowTests` compares every returned record, cursor, and paging flag with the reference store across both directions, sequence/date ordering, filters, redactions, compaction markers, restored histories, and sequence boundaries. The compaction tests also cover exact response limits across 64 KiB buffers, interrupted downloads, and nested image-reference validation.

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

## CI and local simulator automation

CI runs on pull requests to `main`, pushes to `main` or `codex/**`, and manual dispatch. Its two profiles run the ordinary package suite and release build with warnings treated as errors, then execute the signed demo verifier:

- `current` uses `macos-latest` and its newest available iPhone simulator. It also runs the optimized selection above with performance workloads enabled and 40 concurrency waves per adapter.
- `minimum` uses `macos-14`, Xcode 16.2's SDKs, the official Swift 6.1.3 toolchain, and exactly iOS 17.0.1. GRDB 7.10 requires Swift 6.1, so Xcode 16.2's bundled compiler is insufficient. CI verifies the Swift.org installer signature and selects that toolchain for both SwiftPM and Xcode builds. The verifier fails if the requested runtime is unavailable instead of substituting a newer version. The [runner image inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-14-Readme.md) supplies Xcode and the simulator; [Swift.org](https://www.swift.org/install/macos/) supplies the compiler. The job logs the actual host and Swift versions.

The minimum profile selects Xcode's Apple Clang for SwiftPM's C/C++ dependencies: the standalone Swift toolchain's Clang fails to import Realm's `s2geometry` module under C++20. This compiler selection is confined to verification and changes no dependency sources or SDK build flags.

The release workflow runs the current-host checks. A failing optimized test fails the job even though output is also captured for diagnostics. The release workflow skips the new selection when manually dispatched against an older tag without its stress-test source; its existing release-build and legacy simulator checks remain in place.

CI and release revisions containing the verifier run:

```sh
python3 Scripts/check_source_size.py
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests/Verification
python3 Scripts/verify_ios_simulator.py
```

The source guard enforces 600 physical lines for production Swift and repository verification scripts, excluding tests and dependency/build directories. The simulator script builds the Debug demo with ad-hoc signing, selects a compatible installed iPhone runtime, creates a temporary device, and launches `--verify-runtime --verify-local-only`. This launch bypasses ordinary demo setup and does not read a live session. SQLite and Realm each verify plain/structured completion, database reopening, and cancellation. A fresh report with matching run ID must report both adapters passed; missing, stale, partial, or failed reports fail the job. The script removes only its own simulator, including on failure or interruption.

Reports and build/app logs default to `.build/verification`; CI retains them in `runtime-verification-current` and `runtime-verification-minimum` artifacts (`release-runtime-verification` for releases) for 14 days using [GitHub's artifact action](https://github.com/actions/upload-artifact). CI also retains package-test and release-build logs, and reports bounded failure excerpts as job annotations. The current/release artifact contains `codexkit-optimized.log`. Use `--output-dir` to choose a report directory, `--derived-data` to reuse an Xcode build directory, or `--runtime 18.6` to select a specific installed iOS version. Runtime selection defaults to the newest available iPhone-compatible iOS 17+ runtime. Report waiting is bounded to 180 seconds by default, with separate build/boot timeouts.

Manual dispatch for older release tags without these scripts retains the previous compilation-only verification. The report validation and runtime-selection checks run without Xcode via Python's standard `unittest` runner. The full script requires macOS and Xcode with an installed iOS runtime.

## iOS simulator and physical device

Build and run the demo normally for a UI startup check. For automated checks, add `--verify-runtime` to the demo's Run arguments in Xcode. The argument is recognized in Debug builds only and leaves ordinary launches unchanged.

Use a signed app for runtime verification, including on the simulator. The CI script supplies ad-hoc signing; unsigned simulator builds omit the application identity needed by Keychain. For a local simulator build, use:

```sh
xcodebuild -project DemoApp/AssistantRuntimeDemoApp.xcodeproj \
  -scheme AssistantRuntimeDemoApp \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- build
```

This uses local ad-hoc signing. Install that build and launch it with `--verify-runtime`, or run the scheme through Xcode with signing enabled.

The verifier creates temporary, uniquely identified test threads in each managed SQLite/Realm adapter, verifies plain/structured completion, reopens each database, checks cancellation, and deletes those test threads. Unless `--verify-local-only` is supplied, it also attempts the two plain/structured live-provider checks using the demo's existing current session, with ephemeral requests and an in-memory transcript. It never initiates sign-in or refresh. Existing conversations are not used as test input.

Results are written to `Documents/CodexKitVerification.json` in the demo's app container. Retrieve that report using Xcode's container download or the simulator/device tools. It includes timestamps, a run ID, individual `sqlite` / `realm` outcomes, and aggregate `localAdapters` / `liveProvider` outcomes; errors contain codes rather than credentials or provider response content. `skipped: no_current_session` or a Keychain failure requires signing in or correcting the host's Keychain/signing setup before retrying live checks.

On 7 September 2026, before the final cancellation cleanup fix, a signed build installed and launched on the connected iPhone. Its verification report passed the local SQLite, Realm, structured-completion, and cancellation checks. The locally signed iOS 18.6 simulator build passed the same checks and resolved the earlier `keychain_read_failed` result from the unsigned build. The signed simulator build was repeated successfully after the cleanup and definition/tool-output fixes. Both runtime reports returned `skipped: no_current_session` for live-provider checks; the documented Mac SDK and demo Keychain entries also had no current session. Live-provider compatibility still requires sign-in and a completed live check. No physical-device energy measurement has been claimed.
