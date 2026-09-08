# Release readiness — 8 September 2026

The working tree passes local package, release-build, simulator, and performance verification. Live-provider compatibility remains unverified because no current SDK/demo session is saved on this Mac. Changes and release notes remain under `Unreleased`; no release tag or publication was created.

The [storage-lock cancellation issue](storage-lock-audit-2026-09-08.md) is fixed. Cancelled lock acquisitions and queued direct writes stop before acquiring a lease; commits already underway finish atomically. Shared preparation and runtime-owned accepted writes retain their completion and ordering guarantees. Ten new regression tests cover the original failure and cancellation through the storage queues.

## Verification results

| Check | Result | Scope |
| --- | --- | --- |
| Full package suite, warnings as errors | 527 executed: 521 passed, 6 opt-in skips, zero failures | Core, UI, SQLite, Realm, compatibility and regression tests, including six waves per adapter in the new concurrency harness |
| Optimized release build, warnings as errors | Passed | All four SwiftPM library products |
| Optimized performance/SDK/storage selection, warnings as errors | 29 passed, zero failures | Image-heavy compaction, large histories, cancellation, parser, pipeline, SDK ownership, all ten storage regressions and three concurrent lifecycle tests |
| Sustained concurrent lifecycle workload | Passed on all three disk adapters | 40 waves per adapter: 720 overlapping operations, 120 reader reopens, 60 owning-runtime replacements, and independently checked transcripts/attachments |
| Signed simulator execution | Passed | iOS 26.5 / iPhone 17 Pro; plain/structured completion, SQLite/Realm reopening, cancellation |
| Verification harness | 7 passed | Build/run mode separation, portable build settings, failure details, runtime selection and report validation |
| Source-size guard | 211 production files passed | 208 Swift files and three verification scripts, each at most 600 physical lines |
| Source-size boundary checks | Passed | 600 lines accepted; 601 rejected in an isolated fixture repository |
| Workflow YAML and whitespace | Passed | Both workflows parse; `git diff --check` clean |
| Optimized workflow failure propagation | Passed | The exact CI/release shell steps preserve success and failure exit codes through log capture using a local stub command |
| Live tests explicitly enabled | 2 skipped | Neither known SDK/demo Mac Keychain entry contained a current session |

The six ordinary-suite skips are two live tests and four opt-in performance workloads. The latest local package run completed after the cursor and Realm compiler fixes with zero failures in 152.749 seconds. The optimized 29-test selection then passed in 118.035 seconds, and all four library products passed a separate release build with warnings treated as errors. The signed iOS 26.5 simulator check was repeated after the cursor and Realm compiler fixes; run ID `84a31735-7d67-4ece-bdc2-8323af0d6b8b` passed SQLite and Realm completion, reopening, and cancellation on 8 September at 06:13:55 UTC. Live-account access was disabled for that run.

The configured current-host CI checks have been exercised locally: warnings-as-errors, release compilation, the optimized regression selection, the 40-wave concurrency workload, and the simulator script. The hosted macOS 14 package tests and release build passed with Swift 6.1.3. The iOS 17 app is built separately with Xcode 16.4 on macOS 15, then installed and executed on the macOS 14 runner's iOS 17.0.1 simulator; Xcode 16.2's embedded package resolver cannot load Swift 6.1 packages. Hosted completion of the revised simulator handoff remains required. CI retains separate current/minimum package logs and iOS 17 build/runtime reports; the current and release jobs also retain the optimized test log, and log capture preserves test failures. The simulator verifier fails on missing, stale, incomplete, or failed local-adapter reports, creates and removes its own simulator, and skips live-session access explicitly. Manual release dispatch skips the new stress selection for older tags without those tests and retains the original compilation-only simulator fallback for tags that predate the verifier.

## Hosted-verification fixes

Hosted checks exposed two additional SDK issues. History-page equality could fail intermittently because identical cursor payloads used different JSON key orders. Cursor generation now uses canonical key ordering for both cursor versions; three new tests verify stable output and continued decoding of previously issued cursors.

Swift 6.1 also rejected transaction closures that captured Realm values alongside the store actor. Synchronous persistence and attachment-reference helpers now operate on explicit inputs, and memory transactions capture their helper values directly. Realm opening and asynchronous writes stay on the owning actor. No `Sendable` checks were disabled, no dependency sources were edited, and no public adapter API or database schema changed. The complete local suite passed after this extraction.

The minimum profile uses Swift 6.1.3 because GRDB 7.10 already requires Swift 6.1. Model-catalog decoding was simplified to fit that compiler's type-checking budget. Xcode's Apple Clang builds Realm's C++20 dependency modules; the standalone Swift toolchain's Clang could not import `s2geometry` in this configuration.

## Public API compatibility

The release review covered the accumulated core/UI API changes, the database-adapter source diff, CI/release gates, and their changelog/migration guidance.

Swift API Digester compared isolated core/UI modules against local tag `v2.0.0-alpha.26`, commit `87f4d5a700aff88a6da636eba05d48dc2def1e9c`, using the `arm64-apple-macosx14.0` target.

- Core: seven initializer signatures gained defaulted parameters. Representative ordinary calls compile in `PublicAPICompatibilityTests`; exact initializer-as-function references require closure adapters.
- Core: `AgentRuntime.Configuration.authProvider` and `.secureStore` changed to optional types. Host-managed sessions can omit both, so configuration inspection needs optional handling.
- Core: no new protocol requirements were reported, preserving existing backend conformances.
- UI: no removed or changed public declarations were reported.
- Database adapters: the accumulated source diff changes internal relationship filtering and Realm history-window selection, with no public declaration changes.

The [migration guide](migration.md#public-api-review-against-alpha26) includes examples and the reproduction command. API diagnostics live in `.build/api-review`. This review checks the macOS-visible source surface and an iOS consumer build; it is not a binary ABI guarantee or an exhaustive source-compatibility proof for every platform-specific client.

Behavioral changes also require attention: one-shot output now validates before persistence, raw schema support is explicit, skill fields are strict, cancelled startup cannot launch work, overlapping compaction reports busy, and runtime/transport limits have finite defaults. These are documented in the migration guide and changelog.

## Remaining release gates

1. Supply a current SDK/demo session and pass the live plain/structured and image → compaction → database reopen → follow-up checks. The complete image matrix currently runs on the Mac package-test host; signing into a separate iOS device does not populate its Keychain.
2. Pass both package profiles and the separate iOS 17 runtime job in hosted CI for the committed revision intended for release. The reviewed changes are on `codex/release-validation`.
3. Choose the next release version, move the `Unreleased` notes to that version, and create its tag through the normal release process.

The [performance follow-up](performance-2026-09-08.md#implemented-performance-follow-up) batches compact-response bytes, validates image references without expansion, and reads consecutive Realm history windows by primary key. Eight new regression tests passed. The observed eight-image compaction and 20,000-record paging times decreased by 48% and 79% respectively; these local measurements introduce no performance-based release blocker and make no live-provider or physical-device energy claim. These changes add no public API or database schema migration.
