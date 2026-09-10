# Reusing a local Codex login on macOS

[Documentation index](index.md) · [Integration example](../Examples/LocalCodexSession.swift)

For a runnable native app, open `DemoApp/CodexKitDemo.xcodeproj` and select the `CodexKitMacDemo` scheme. This project contains both the iOS and macOS demo targets. The [macOS demo walkthrough](../DemoApp/README.md#macos-demo) covers local connection, device-code fallback, chat, and the signed app's offline integration checks.

CodexKit can borrow a compatible, accessible local ChatGPT access token while retaining its existing Responses backend, tool loop, typed requests, and structured outputs. The credential owner remains responsible for its login and refresh token. CodexKit never starts Codex to force refresh, calls Codex logout, or writes to external credential storage.

## Configuration and discovery

Create `CodexLocalSessionSource` with a closure returning `CodexLocalSessionConfiguration`. The closure must supply the owner's **effective** selected home, storage mode, login restriction, allowed workspaces, and ChatGPT service URL. It is called again during resolution. Storage is intentionally required; the adapter does not guess configuration by scanning multiple homes or accounts.

The consuming host resolves configuration precedence, including CLI/profile overrides, local requirements, and macOS managed configuration. CodexKit does not implement Codex's TOML/MDM configuration loader or inspect another process's environment. A host that cannot establish those settings should report discovery unavailable and offer its interactive login. For a known configuration, for example:

```swift
let source = CodexLocalSessionSource(configuration: {
    CodexLocalSessionConfiguration(
        codexHome: selectedCodexHome,
        storage: .auto,
        forcedLoginMethod: "chatgpt",
        allowedWorkspaceIDs: permittedWorkspaceIDs
    )
})
let candidate = try await source.discover()
```

`selectedHome(environment:userHome:)` implements explicit `CODEX_HOME` or the supplied user's `.codex` directory. GUI applications should pass their selected home; their environment need not match a shell's environment.

Supported storage:

| Owner configuration | Behavior |
| --- | --- |
| `file` | Read `auth.json` from the selected canonical home. |
| `keyring`, direct backend | Read the macOS generic-password service `Codex Auth`, account `cli\|` followed by the first 16 lowercase SHA-256 hex characters of the canonical home path. |
| `auto`, direct backend | Prefer Keychain. Fall back to the selected file only when Keychain has no item or is unavailable. |
| `ephemeral` | Report `storageUnavailable`: another process's memory is not discoverable. |
| encrypted `secrets` Keychain backend | Report `unsupportedStorage`; no attempt to decrypt or fall back to stale direct credentials. |

Unlike Codex's broad `auto` fallback, CodexKit does not hide Keychain denial or malformed data by choosing a file. Once a source resolves successfully, storage/configuration changes require a new explicit connection. If its bound Keychain item disappears, an old fallback file cannot resurrect that session.

Only ChatGPT mode is supported. API keys, external-token process auth modes, agent identity, personal access tokens, Bedrock, FedRAMP routing, and nonstandard ChatGPT service URLs are rejected explicitly. JWT payloads supply expiry, workspace, and user identity; conflicting claims are rejected. Payload decoding is not signature verification or proof of server acceptance. Unknown expiry is rejected by local discovery. `discover()` reports expired credentials; `resolve()` can return an expired snapshot so the manager can ask the owner to renew it.

## Session lifecycle

Use one `ChatGPTSessionManager` as the runtime's `sessionProvider`. `connectExternalSession(source:expectedBinding:owner:)` explicitly binds discovery. Save only its `ChatGPTSessionBinding` and the application-selected mode, then pass that binding on subsequent launches. Do not save or encode the borrowed `ChatGPTSession` into application persistence.

The manager re-reads the bound source before use and after unauthorized responses. It accepts rotation only for the same source, workspace, and user. It coalesces owner renewal requests, allows individual waiters to cancel, and rejects late results after disconnect or replacement. The injected `ChatGPTSessionStoring` initializer accepts a clock and an owner-renewal timeout (default 15 seconds) for deterministic testing. The read-only source never decodes the refresh token into its session; ID tokens are used only to extract metadata and then discarded.

`ChatGPTSessionOwnerRenewing` is an extension point for an actual credential-owner integration. It receives the non-secret binding and must request renewal through that owner. Afterward the manager re-reads the same source. Implementations should throw `transientFailure` or `revokedCredentials` when known. Raw provider/store errors are replaced with safe typed errors.

**Unattended renewal is conditional.** No built-in public broker integration is provided. With no owner capability, CodexKit can adopt tokens rotated by Codex, but it returns `reconnectRequired` when no usable rotation exists. A running second Codex process is not evidence of coordinated ownership. The App Server external-token refresh protocol expects its host to supply renewed credentials; it is not a broker for borrowing a different client's session.

`authenticationState()` on the manager/runtime exposes status, expiry, and a typed failure without tokens or account identifiers. Refresh that snapshot after authentication actions or failed operations. It is not a filesystem watcher or push notification stream; source logout/account changes are detected at resolution boundaries. An existing HTTP stream may finish before the next source read detects external logout.

## Runtime and account isolation

The built-in backend resolves a lease before each HTTP pass, including after tools and approval waits. A rejected pass can be retried once with renewed credentials before that pass emits output. Earlier tool executions and visible output are not replayed. Transport retries retain their existing bounds. HTTP 403 is a permission error, not an automatic token-refresh trigger. Thread creation/resume, model discovery, memory extraction, and compaction use the shared provider; third-party backends retain their existing protocol and must implement any internal multi-request renewal themselves.

New threads persist their source/workspace/user binding in their existing encoded metadata. A mismatching session cannot resume, send, or compact that conversation. Legacy unbound threads remain readable, but external sessions must start a new conversation. Legacy app-owned threads bind on first send/resume. This is an additive serialized field; no SQL/Realm schema migration is needed. Older library versions do not enforce these bindings, so do not share an active store with older versions after adopting external authentication.

Disconnect cancels runtime-managed executions, including ephemeral turns. Event/tool-result checks reject stale sessions after manager replacement. Completed local history remains available for application-controlled display; isolation blocks its transmission under another binding. Model/rate-limit caches are partitioned by the full binding.

If memory is configured, provide an account-partitioned memory store and set `AgentMemoryConfiguration.authenticationBinding`. External sessions reject an unbound memory configuration. The library validates the declared binding; the application must actually partition the underlying stores and construct a matching runtime when switching accounts.

## macOS access and verification

| Consuming application | Contract |
| --- | --- |
| Unsandboxed signed app | Reads only what its existing filesystem and Keychain permissions allow. |
| Sandboxed app | The host must obtain and retain access to the selected home where required. Passing a path does not grant access. |
| Keychain denies access, is locked, or needs interaction | Noninteractive `LAContext` returns a typed failure; background discovery does not show an authentication prompt. |
| iOS | Shared ownership/resolver APIs remain available; the native macOS reader is not compiled. |

Synthetic fixture tests cover storage selection/failures, binding restoration, expiry, rotation, owner failure/timeout, concurrent waiters, disconnect races, mid-tool-pass renewal, model discovery, compaction, and SQLite restoration under another identity. They never read the user's real Codex credentials. Run `python3 Scripts/verify_local_codex_session.py` for an ad-hoc-signed macOS smoke test. It seeds a fresh synthetic home and Keychain item, verifies all three readable storage modes, verifies disconnect preserves both payloads, and removes the fixtures. This probe passed on the development Mac.

Signed-app entitlements, Keychain ACLs belonging to an independently installed Codex, and host security-scoped access still require validation in the consuming app; passing unit tests cannot promise access to another app's credentials.

Storage details were inspected in OpenAI Codex source revision `459a79eb85400af759e9220c7bafb4429ae07516`:

- [Storage implementation](https://github.com/openai/codex/blob/459a79eb85400af759e9220c7bafb4429ae07516/codex-rs/login/src/auth/storage.rs)
- [Token data and claims](https://github.com/openai/codex/blob/459a79eb85400af759e9220c7bafb4429ae07516/codex-rs/login/src/token_data.rs)
- [Storage defaults](https://github.com/openai/codex/blob/459a79eb85400af759e9220c7bafb4429ae07516/codex-rs/config/src/types.rs)
- [Official authentication documentation](https://learn.chatgpt.com/docs/auth)
- [Official configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference)
- [Official App Server authentication](https://learn.chatgpt.com/docs/app-server)

## Verification record — 10 September 2026

- Full package suite with warnings treated as errors: 556 tests, six opt-in skips, zero failures. Includes 24 new discovery/lifecycle/runtime tests.
- Final targeted authentication/runtime suite: 72 tests passed.
- Ad-hoc-signed macOS synthetic probe: file, Keychain, auto, and disconnect preservation passed.
- Core and UI modules compiled for the iOS 17 simulator target with warnings treated as errors; no simulator execution was performed for this change.
- Public API comparison against the starting commit reported no source-breaking diagnostics for core or UI. This is not an ABI guarantee.
- Source-size guard: all 219 production files remained within 600 physical lines. Integration example type-check passed.

Earlier broad runs intermittently failed two existing persistence assertions (concurrent failed-write recovery and Realm corruption visibility); both passed the final full run without changes to their persistence implementation. No live Codex credentials or model endpoints were used for this verification.

### Native demo and real-session follow-up — 10 September 2026

- Native demo Debug and universal Release builds passed; the signed app's 11 offline integration checks passed.
- With explicit user authorization, the native demo connected to the existing `~/.codex/auth.json` session using file storage, without interactive sign-in.
- A live request using `gpt-5.6-sol` completed and returned the requested marker, `CODEXKIT_REAL_SESSION_OK`.
- Quitting and relaunching the demo restored the authenticated session and the committed conversation.
- Disconnect cleared the demo session and remained disconnected after another relaunch.
- The credential file's SHA-256 matched before and after the entire test. No borrowed access, refresh, or ID token appeared in the demo's persisted conversation files.

This establishes real-session reuse for the tested disk-backed installation and signed, unsandboxed demo. It does not establish cross-app Keychain ACL access, sandboxed access, or renewal after this real token expires.

### Expanded macOS demo

The macOS demo now offers browser OAuth and device-code sign-in alongside local-session reuse, plus tools/approvals, personas/skills, images, typed output, memory, and runtime inspection. The expanded SDK suite passed 557 tests with six opt-in skips and no failures. The signed app passed 20 offline checks spanning authentication, typed output, parallel tools, approvals, compaction, and File/SQLite/Realm persistence. Additional targeted tests cover account-directory storage isolation and rejection of host database files.

A live typed shipping-draft request also completed through the signed app using the existing local Codex session, with the owner credential file unchanged. The native UI inspection helper crashed during the walkthrough, so that walkthrough remains incomplete.

### OAuth workspace recovery

The user completed browser OAuth and reported an authenticated sidebar alongside a generic restoration failure. A rebuilt signed app successfully restored that saved OAuth session and opened its workspace. The original error was hidden, so its precise cause could not be recovered from that run.

The demo now avoids a second Keychain read and authentication lifecycle reset when opening the workspace after sign-in. It saves the authentication choice before opening local data, reports the underlying workspace error, and supports retrying with the current session or explicitly reopening a previously saved ChatGPT session. Signed-app regression checks cover native Keychain handoff, relaunch, missing preferences, workspace corruption, and recovery without reacquiring or changing credentials. SDK OAuth/UI/external-runtime regressions passed 16 tests.

The signed app passed all 25 integration checks, and Debug and universal Release builds succeeded. The real saved-session restoration and live OAuth reply checks passed: the signed app received the expected `CODEXKIT_OAUTH_SESSION_OK` reply using temporary conversation storage and confirmed the saved credentials were unchanged. The Keychain prompt required user interaction because computer use cannot interact with SecurityAgent. After the project and target renames, the user also confirmed the demo was working.
