# Alpha.28 release preparation — 10 September 2026

The candidate is **v2.0.0-alpha.28** on `codex/release-alpha28`, based on `f7e845cc6546e5ac745aa1a6fc05e720bb5d9f8e`. Remote tags were checked on 10 September; `v2.0.0-alpha.27` is the latest published tag in this series. This candidate has not been tagged or published.

## Release scope

- Read-only reuse of a locally authenticated Codex installation on macOS, with explicit effective settings, credential ownership, source/account/user binding, safe failure states, and optional owner-coordinated renewal.
- Authentication checks before provider requests and after tool/approval waits, with bounded recovery that preserves account binding and does not repeat earlier tool effects.
- A native macOS demo with local-session reuse, browser OAuth, device-code sign-in, chat, tools, approvals, typed output, personas/skills, images, memory, and File/SQLite/Realm persistence.
- One `DemoApp/CodexKitDemo.xcodeproj` with `CodexKitIOSDemo` and `CodexKitMacDemo` targets and schemes. Existing iOS bundle, Keychain, and settings identifiers are preserved.
- Account-directory persistence initializers, SwiftUI request/progress helpers, macOS workspace recovery after OAuth, and simulator container-lookup reliability.
- macOS demo execution in current-host CI and the release verification workflow, with retained build logs and verification results.

The versioned [changelog](../CHANGELOG.md#200-alpha28---2026-09-10) supplies the GitHub release body. The [migration guide](migration.md#local-codex-sessions-alpha28) covers the external-session and demo-path changes. Swift 6.1, iOS 17, and macOS 14 remain the minimum versions. No database schema migration is required.

## Local verification

Checks ran on macOS 26.6.2 with Apple Swift 6.3.3. Demo checks ran after the final project/target rename; subsequent changes are release documentation and workflow wiring.

| Check | Result | Local evidence |
| --- | --- | --- |
| Full SDK suite, warnings as errors | 560 executed, 6 opt-in skips, zero failures | `.build/alpha28-package-tests.log` |
| Release library build, warnings as errors | All four library products passed | `.build/alpha28-release-build.log` |
| Optimized regression/performance/concurrency checks | 29 passed; 40 rounds per adapter; zero failures | `.build/alpha28-optimized-tests.log` |
| Signed macOS demo | 25 checks passed | `.build/macos-demo/build.log`, `.build/macos-demo/verification-result.json` |
| Signed native credential probe | File, Keychain, and auto discovery/disconnect passed with synthetic credentials | `.build/alpha28-native-auth-probe.log` |
| Signed iOS simulator demo | SQLite, Realm, reopening, completion, and cancellation passed | `.build/verification/CodexKitVerification.json` |
| Verification script tests | 11 passed | `.build/alpha28-harness-tests.log` |
| Source-size guard | 235 production files, each at most 600 physical lines | `.build/alpha28-source-size.log` |
| Core/UI source API comparison with alpha.27 | No removed public declarations or changed existing protocol requirements | `.build/alpha28-api-review/` |

The iOS verifier ran on iOS 26.5 / iPhone 17 Pro, completed at `2026-09-10T10:09:09Z`, and removed its temporary simulator. Live-account access was disabled for that run. The ordinary package suite skips two opt-in live-provider tests and four performance workloads; the optimized selection separately enables performance and 40 concurrency rounds per adapter.

The optimized selection completed in 111.252 seconds. File, SQLite, and Realm stress workloads each performed 240 operations with six concurrent workers, 40 reader reopens, and 20 runtime reopens. Across adapters, 720 operations passed the independent transcript and attachment checks. Both workflow YAML files parsed successfully; 161 relative documentation/file links and the release workflow's alpha.28 changelog extraction were checked. Historical absolute links to old local audit artifacts were excluded from the relative-link check.

The API digester's sole enum diagnostic adds `invalidStorageDirectory` to package-scoped `CodexKitManagedStorageError`. That implementation type is not a public host-app API. Public SQLite/Realm directory initializers are also exercised by `ScopedStorageTests`; the digester script compares core/UI modules only. These checks do not establish binary ABI compatibility.

## Real-session and manual evidence

- The signed macOS demo reused the existing local disk-backed Codex session and completed a typed shipping-draft request. Disconnect left the owner credential file unchanged. The result is `.build/alpha28-local-live-features.json`.
- After the user completed browser OAuth, the signed demo restored that saved session and received exactly `CODEXKIT_OAUTH_SESSION_OK` from a live request using temporary conversation storage. Saved Keychain credentials were unchanged. The result is `.build/alpha28-oauth-live-reply.json`.
- The user confirmed the renamed demo was working. OAuth Keychain access required user interaction with the macOS system prompt.

These checks establish the tested local-session and saved-OAuth paths. They do not establish access to another application's Keychain item under every ACL, sandboxed access, device-code sign-in in this release, or unattended renewal after the real owner token expires. No built-in credential-owner renewal broker is provided.

Local verification artifacts remain under ignored `.build/`; credentials and private account data are not committed.

## Publication handoff

The user authorized publication of alpha.28 on 10 September. The following steps remain gated on successful hosted checks.

1. Push the candidate branch and review the hosted CI results, including minimum-platform jobs. Hosted CI has not yet run for this candidate; earlier release CI results do not substitute for this run.
2. The README's release badge/link now targets alpha.28. Fast-forward the reviewed candidate onto `main` and create an annotated `v2.0.0-alpha.28` tag.
3. Push the tag. The release workflow verifies the tagged revision, library tests/builds, optimized checks, and both demo verifiers before creating the GitHub prerelease from the alpha.28 changelog entry.

The repository currently has no alpha.28 tag or published release. Preparing these files does not trigger publication.
