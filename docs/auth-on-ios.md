# ChatGPT Auth on iOS

## Upstream Codex Model

Codex separates:

- ChatGPT auth acquisition
- token persistence
- token refresh
- externally managed token refresh callbacks

Those concepts port cleanly to iOS. The desktop transport does not.

The important upstream ideas we keep are:

- a durable ChatGPT session model
- refresh-on-demand behavior
- host-provided refresh seams
- account metadata extraction from auth tokens

## Recommended iOS Design

The iOS host app owns:

- when sign-in starts
- what sign-in UI is shown
- Keychain policy selection if it wants to customize storage
- approval and prompt presentation

The runtime owns:

- session lifecycle
- refresh coordination
- account/session restoration
- normalization into `ChatGPTSession`

## Default Live Path

The recommended live iOS path in this repo is now:

1. host app creates `ChatGPTDeviceCodeAuthProvider`
2. host app provides `DeviceCodePromptCoordinator` from `CodexKitUI`
3. runtime starts sign-in through `AgentRuntime.signIn()`
4. device-code prompt state is surfaced to SwiftUI
5. user completes ChatGPT sign-in in the verification flow
6. runtime exchanges the authorization code for tokens
7. runtime persists the resulting `ChatGPTSession` with `KeychainSessionSecureStore`
8. `ChatGPTSessionManager` refreshes later when needed

This matches Codex’s auth lifecycle while avoiding desktop-only redirect assumptions.

## Why Device Code Is Recommended

The redirect-based browser OAuth path from Codex is useful, but on iOS it depends on upstream redirect acceptance and presentation details that are more fragile than the device-code flow.

For that reason:

- `ChatGPTDeviceCodeAuthProvider` is the default documented iOS sign-in path
- `ChatGPTOAuthProvider` remains available for advanced integrations

## Advanced Browser OAuth Path

When an app specifically wants a browser callback flow, it can still use:

- `ChatGPTOAuthProvider`
- `SystemChatGPTWebAuthenticationProvider`
- a custom redirect URI

That path preserves Codex’s PKCE and token exchange model, but it is not the default recommendation for first-time integration.

## Secure Storage

The default storage is:

- `KeychainSessionSecureStore`
- `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`

Why:

- survives relaunch
- stays inside iOS sandbox constraints
- avoids plaintext token files

Apps can still swap storage with `SessionSecureStoring`, but Keychain is the normal production path.

## Session Lifecycle

At launch:

1. app creates `AgentRuntime` with a configured auth provider and secure store
2. app calls `restore()`
3. `ChatGPTSessionManager` loads any stored `ChatGPTSession`
4. app reads current session state through `AgentRuntime.currentSession()`

At request time:

1. runtime requires a valid session
2. runtime refreshes if the session is near expiry
3. runtime uses the refreshed session for backend calls

At logout:

1. runtime clears the in-memory session
2. runtime deletes the Keychain session
3. UI updates immediately

## Error Model

The auth layer should surface user-meaningful failures such as:

- sign-in cancelled
- missing session
- callback mismatch
- token exchange failed
- refresh failed
- auth edge challenge / rate-limit failure

These are normalized through `AgentRuntimeError` rather than leaking raw transport details into app UI.

## First-Class Types In This Repo

The current auth surface is:

- `ChatGPTSession`
- `ChatGPTAuthProviding`
- `SessionSecureStoring`
- `KeychainSessionSecureStore`
- `ChatGPTSessionManager`
- `ChatGPTDeviceCodeAuthProvider`
- `ChatGPTOAuthProvider`
- `DeviceCodePromptCoordinator` in `CodexKitUI`

## Bottom Line

Port the Codex auth model, not Codex’s desktop login transport.

The intended mapping is:

- Codex `AuthManager` -> `ChatGPTSessionManager`
- Codex external refresher seam -> `ChatGPTAuthProviding.refresh`
- Codex device-code login model -> `ChatGPTDeviceCodeAuthProvider`
- Codex file/keyring persistence -> `KeychainSessionSecureStore`
- app-facing prompt state -> `DeviceCodePromptCoordinator`
