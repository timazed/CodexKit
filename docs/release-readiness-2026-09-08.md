# Release readiness — 8 September 2026

The working tree passes local package, release-build, simulator, and performance verification. Live-provider compatibility remains unverified because no current SDK/demo session is saved on this Mac. Changes and release notes remain under `Unreleased`; no release tag or publication was created.

The [storage-lock cancellation issue](storage-lock-audit-2026-09-08.md) is fixed. Cancelled lock acquisitions and queued direct writes stop before acquiring a lease; commits already underway finish atomically. Shared preparation and runtime-owned accepted writes retain their completion and ordering guarantees. Ten new regression tests cover the original failure and cancellation through the storage queues.

## Verification results

| Check | Result | Scope |
| --- | --- | --- |
| Full package suite, warnings as errors | 524 executed: 518 passed, 6 opt-in skips, zero failures | Core, UI, SQLite, Realm, compatibility and regression tests, including six waves per adapter in the new concurrency harness |
| Optimized release build, warnings as errors | Passed | All four SwiftPM library products |
| Optimized performance/SDK/storage selection, warnings as errors | 29 passed, zero failures | Image-heavy compaction, large histories, cancellation, parser, pipeline, SDK ownership, all ten storage regressions and three concurrent lifecycle tests |
| Sustained concurrent lifecycle workload | Passed on all three disk adapters | 40 waves per adapter: 720 overlapping operations, 120 reader reopens, 60 owning-runtime replacements, and independently checked transcripts/attachments |
| Signed simulator execution | Passed | iOS 26.5 / iPhone 17 Pro; plain/structured completion, SQLite/Realm reopening, cancellation |
| Verification harness | 4 passed | Runtime selection and stale/incomplete/failed report rejection |
| Source-size guard | 210 production files passed | 207 Swift files and three verification scripts, each at most 600 physical lines |
| Source-size boundary checks | Passed | 600 lines accepted; 601 rejected in an isolated fixture repository |
| Workflow YAML and whitespace | Passed | Both workflows parse; `git diff --check` clean |
| Optimized workflow failure propagation | Passed | The exact CI/release shell steps preserve success and failure exit codes through log capture using a local stub command |
| Live tests explicitly enabled | 2 skipped | Neither known SDK/demo Mac Keychain entry contained a current session |

The six ordinary-suite skips are two live tests and four opt-in performance workloads. The performance workloads passed in the separate optimized run. The final simulator report's run ID was `07411767-8846-46df-ad37-474d2fed776d`, recorded after the storage-lock fix. The later concurrency/CI additions change no production Swift code, so that simulator check was not repeated for them.

The configured current-host CI checks have been exercised locally: warnings-as-errors, release compilation, the optimized regression selection, the 40-wave concurrency workload, and the simulator script. CI also has a minimum-OS profile using macOS 14, Xcode 16.2 SDKs with the official Swift 6.1.3 toolchain, and exactly iOS 17.0.1; that combination is unavailable on this Mac and still requires hosted verification. A hosted GitHub Actions run remains required on the release revision. CI retains separate current/minimum simulator reports and logs; the current and release jobs also retain the optimized test log, and log capture preserves test failures. The simulator verifier fails on missing, stale, incomplete, or failed local-adapter reports, creates and removes its own simulator, and skips live-session access explicitly. Manual release dispatch skips the new stress selection for older tags without those tests and retains the original compilation-only simulator fallback for tags that predate the verifier.

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
2. Commit the reviewed changes and pass both current-host and minimum-OS profiles in hosted CI for the revision intended for release.
3. Choose the next release version, move the `Unreleased` notes to that version, and create its tag through the normal release process.

The [performance follow-up](performance-2026-09-08.md#implemented-performance-follow-up) batches compact-response bytes, validates image references without expansion, and reads consecutive Realm history windows by primary key. Eight new regression tests passed. The observed eight-image compaction and 20,000-record paging times decreased by 48% and 79% respectively; these local measurements introduce no performance-based release blocker and make no live-provider or physical-device energy claim. These changes add no public API or database schema migration.
