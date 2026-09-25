# Account metadata verification

This fix is unreleased. It targets the alpha.31/alpha.32 metadata defect; no release tag or merge is authorized by this work.

## Initial fix local evidence

- Full locked-dependency Debug suite with warnings as errors: 729 tests across the core and recovery integration targets, seven opt-in skips, zero failures. The skips are three live-provider tests and four extended benchmarks. No live authentication or model requests were made.
- Optimized locked-dependency correctness lane with warnings as errors: all 64 tests passed, including the metadata regressions and six-round storage concurrency workload.
- Signed synthetic local-session probe: passed file, Keychain, auto storage, discovery, and disconnect.
- Signed macOS full offline verifier: passed, including authentication restoration, account isolation, rotation, logout, and validated-result retrieval in a second process with zero generation POSTs.
- Signed iOS 27.0 simulator full offline verifier: passed SQLite, Realm, streaming, cancellation, controlled recovery, and second-process result retrieval; live-provider verification explicitly disabled.
- Source-size guard: 294 production files passed the 600-line limit. Whitespace checks passed. All 38 Python verification-harness tests passed.
- Public API comparison against `v2.0.0-alpha.32` (`064427309e8f734f223af2c75541858312372de2`): nine plan enum cases added; no declarations removed and no CodexKitUI API changes. Exhaustive switches and downgrade implications are documented in [compatibility](account-metadata-compatibility.md).

The signed synthetic local-session probe explicitly selects SwiftPM's native build system because its standalone linker consumes native object maps; the newer Xcode default emits a different layout. This fixes the verification harness, not authentication behavior.

## Regression assertions

`AccountMetadataResolutionTests` covers Free and paid plans, every audited upstream plan variant/alias, legacy claims, namespace and token precedence, access-token fallback, malformed/unsupported plans, account/user conflicts, both concrete refresh providers, device-code sign-in through the session manager, and isolated Keychain cold restoration/reopening/logout. It verifies exact persisted credentials and account metadata, retained names and refresh tokens, unchanged storage after rejected identity changes, and unknown rather than stale paid classification for explicitly unsupported refresh plans. Browser OAuth exchange retains its existing transport regression with a namespaced fixture.

Existing external-session and runtime regressions exercise local discovery restrictions and binding safety. Tests substitute external authentication transport and use synthetic credentials; they do not modify Pocket POTUS, Pineapple, or real authentication stores.

## Promotion gates

The development Mac has only the current Xcode and no iOS 17 runtime. Minimum Swift/macOS and iOS 17 checks must pass in hosted CI, along with all other mandatory lanes, for the exact commit before release promotion. A local pass is not a substitute for those lanes. No ready PR, merge, tag, or release is created by this verification report.

## Implementation review follow-up

`ChatGPTAccountResolver` is an instance holding a decoded ID/access-token pair. Token parsing uses typed `Decodable` session metadata (`ChatGPTSessionMetadata`) and initializer-based construction; missing, malformed, and present fields have explicit enum states. Session construction/repair lives in focused extensions. This removes the static utility namespace, untyped payload dictionary, runtime casts, optional parsing chains, and duplicate refresh decoding. Additional parser regressions cover malformed neighboring fields, namespace fallback, invalid token structure, and Boolean timestamps.
