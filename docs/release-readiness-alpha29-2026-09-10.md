# Alpha.29 release verification — 10 September 2026

The user authorized publication of `v2.0.0-alpha.29`. The candidate is prepared on `codex/release-alpha29` from `bde77d5ccaf4238b2e172046c06d4efa461c0a8c`. At preparation, GitHub's latest published prerelease was alpha.28 and remote main matched that baseline.

## Scope and compatibility

- The built-in Responses backend permits only `.clientManaged`, always sends `store: false` and encrypted reasoning input, and no longer chains generation or compaction with `previous_response_id`.
- `.serverManaged` is removed. Existing defaults and explicit `.clientManaged` calls remain supported. Decoding the former enum value fails. A saved context containing only a server response ID fails before HTTP; contexts with local items retain them. No database schema migration is required.
- Controlled transport tests and a redacted live capability report distinguish request replay, conversation restoration, result retrieval, and stream resumption. No recovery API or replacement-request fallback is introduced.
- Updated retry documentation, migration guidance, release notes and version links.

See [migration notes](migration.md#client-managed-state-only-alpha29) and the [endpoint investigation](response-recovery-investigation-2026-09-10.md). Swift 6.1, iOS 17 and macOS 14 remain the minimum versions.

## Local checks

| Check | Result | Evidence |
| --- | --- | --- |
| Targeted transport, compaction, auth and recovery tests | 76 passed, zero failures | `.build/client-managed-only-tests.log` |
| Full package suite, warnings as errors | 575 executed, 6 expected opt-in skips, zero failures | `.build/client-managed-release-tests.log` |
| Optimized library build, warnings as errors | All four library products passed | `.build/client-managed-release-build.log` |
| Verification harness tests | 11 passed | `.build/client-managed-harness-tests.log` |
| Source-size guard | 236 production files, all at most 600 lines | `Scripts/check_source_size.py` |
| Diff whitespace and investigation links/probe syntax | Passed | Local verification |
| Public core/UI API comparison with alpha.28 | Only `.serverManaged` removed; no other diagnostics | `.build/alpha29-api-review/` |

The full suite completed in approximately 141 seconds. Six skips cover two live-account tests and four opt-in performance workloads. System Contacts-service connection failures were logged during tests, without assertion failures. No new live account calls were made for these package tests.

The earlier authenticated probe completed small tool-free structured requests. The endpoint rejected `store: true` and `background: true`; real-ID retrieval/cursor GETs, including original routing headers, encountered Cloudflare challenges. This does not establish absence of origin recovery support. [Sanitized evidence](response-recovery-probe-2026-09-10.json) contains no credentials, account identifiers, response identifiers, or generated text.

## Hosted verification and publication

[Candidate CI run 34477083294](https://github.com/timazed/CodexKit/actions/runs/34477083294) passed for `b1e71aa22632f01102ee5b399c585af0c8ba1d89`:

- Current-platform package tests, release build, optimized regression/concurrency checks, and the iOS/macOS demo verifiers.
- Minimum-platform package tests and release build.
- Swift 6.1 iOS 17 verifier build.
- iOS 17 runtime verification.

Only this verification record changes after the tested candidate. The tag-triggered workflow will verify the exact release revision before creating the GitHub prerelease. Publication remains pending until that workflow passes.
