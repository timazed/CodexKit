# Release candidate — 9 September 2026

The candidate is `v2.0.0-alpha.27` on `codex/release-validation`. Its code commit is `8da0900fff95ce28e4fe403b68157fd9da3c1bf0`, based on `aef6820276e67ff7e9b770834b7e0fb39b2ef173`. Remote tags were checked on 9 September: `v2.0.0-alpha.26` remains the latest tag in this series. Publication is held for manual demo verification. The versioned changelog and migration notes include the account-name addition.

## Account-name behavior

Browser OAuth and device-code sign-in/refresh read the optional `name` claim from the ID token. `ChatGPTAccount.displayName` trims surrounding whitespace and falls back to email for absent or blank names. The demo's signed-in header uses this property.

Existing saved sessions without `name` still decode. The original three-argument account initializer is preserved, including initializer-as-function references. Tests cover Unicode, missing/null/blank names, both authentication methods, token refresh, JSON round trips, and runtime Keychain persistence. The new initializer-reference regression was reproduced as a compiler failure before preserving the original overload.

## Local verification

| Check | Result | Evidence |
| --- | --- | --- |
| Release build, warnings as errors | Passed, all four library products | `.build/account-name-release-build.log` |
| Final package suite, warnings as errors | 532 executed: 526 passed, 6 opt-in skips, zero failures | `.build/account-name-release-package-tests.log` |
| Optimized regression/performance/concurrency checks | 29 passed, zero failures; 40 rounds per adapter | `.build/account-name-optimized-tests.log` |
| Signed demo build | Passed | `.build/account-name-demo-final-build.log` |
| Signed simulator runtime | Passed: SQLite, Realm, reopening, completion, cancellation | `.build/account-name-simulator-verification/CodexKitVerification.json` |
| Verification harness | 7 tests passed | `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests/Verification` |
| Production source-size guard | 211 files passed, each at most 600 lines | `python3 scripts/check_source_size.py` |
| Public API comparison against alpha.26 | Reviewed; no additional breaking diagnostics from account-name support | `.build/account-name-api-review/` |

The simulator run used iOS 26.5 / iPhone 17 Pro, run ID `b9b4cd38-ff6b-4417-9b47-89d7250f5d0a`, finishing at `2026-09-09T04:09:57Z`. It ran the final signed demo build in a disposable simulator and explicitly disabled live-account access. The temporary simulator was removed afterward. The built app remains at `.build/simulator-verification/Build/Products/Debug-iphonesimulator/AssistantRuntimeDemoApp.app`.

The optimized selection completed in 93.012 seconds. Its file, SQLite, and Realm concurrency checks each ran 40 rounds with six workers: 720 total lifecycle operations, 120 reader reopens, and 60 owning-runtime replacements. All passed independent transcript and attachment checks.

The full package suite completed in 137.085 seconds. Its six skips are the two live-provider tests and four opt-in performance workloads; the latter were enabled in the separate optimized run above.

The API comparison still reports the seven earlier default-parameter initializer changes and two optional configuration properties documented in the [migration guide](migration.md#public-api-review-against-alpha26). It reports no removed/changed public UI declarations or new core protocol requirements. It does not establish binary ABI compatibility.

Local logs are retained under `.build/` and are not committed.

## Hosted verification

All four jobs in the [candidate CI run](https://github.com/timazed/CodexKit/actions/runs/34310334995) passed for code commit `8da0900fff95ce28e4fe403b68157fd9da3c1bf0`: current and minimum package/release verification, the Swift 6.1 iOS 17 build, and actual iOS 17 runtime verification. The current job also passed optimized regression/concurrency checks and signed simulator execution. Final job status is retained locally in `.build/account-name-hosted-ci.json`.

This final results update changes documentation only; it does not change the verified SDK, tests, demo sources, or workflows. Hosted CI retains its own package, optimized-test, and simulator evidence.

## Manual demo checks

1. Open `DemoApp/AssistantRuntimeDemoApp.xcodeproj` in Xcode, select `AssistantRuntimeDemoApp`, and run on your device or simulator. The shared scheme starts the normal UI without `--verify-runtime`.
2. Complete a fresh sign-in and inspect **Signed in as** on the Assistant tab. Expect the account name when supplied by authentication, otherwise the email. A restored older session can remain on the email fallback until sign-in or token refresh supplies a name.
3. Close and relaunch the app. Confirm the saved session and displayed name/email are restored.
4. Send a short message and confirm normal replies still work. If you use both browser and device-code sign-in, check each flow.
5. Report whether a real account name appeared and whether sign-in, restoration, and messaging worked. Do not share raw tokens.

Name availability in real service tokens remains unverified: the two documented SDK/demo Mac Keychain entries had no saved session. The existing live plain/structured and image-compaction/reopen tests also remain unverified for this candidate; the Mac tests need a Mac SDK/demo session, separate from an iOS device's session.

## Publication handoff

- Keep the candidate on `codex/release-validation` while the demo is being checked.
- Hosted CI is complete. Record the manual/live verification outcome before publication.
- Once approved, update README release links to alpha.27, bring the reviewed candidate onto `main`, and create an annotated `v2.0.0-alpha.27` tag on the approved release commit.
- Pushing that tag triggers the release workflow, which repeats its required checks before publishing the GitHub prerelease. No release tag should be pushed before approval.
