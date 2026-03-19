# ChatGPT Auth on iOS

## Upstream Codex Model

Codex currently splits auth into two important layers:

### Managed ChatGPT auth

References:

- `codex-rs/login/src/server.rs`
- `codex-rs/core/src/auth.rs`

Flow:

- start browser login
- receive callback on localhost
- exchange code for tokens
- persist auth payload
- refresh tokens later from `AuthManager`

### Externally managed ChatGPT auth

References:

- `codex-rs/core/src/auth.rs`
- `codex-rs/app-server/src/message_processor.rs`
- `codex-rs/app-server-protocol/src/protocol/v2.rs`

Flow:

- host app injects `chatgptAuthTokens`
- runtime treats tokens as externally managed
- on unauthorized, runtime asks host for a refreshed token

For iOS, the same upstream auth primitives are reusable, but the browser transport must be replaced.

## Recommended iOS Adaptation

## Design Principle

The iOS host app should own the auth UX entry point and secure-storage policy.

The runtime should own:

- session state
- secure persistence
- refresh coordination
- account metadata exposure

The host app should own:

- app-specific sign-in entry UI
- redirect URI registration
- any app-specific account/session policy

## Proposed Flow

1. host app creates a `ChatGPTOAuthProvider` with its redirect URI
2. runtime starts sign-in using `ASWebAuthenticationSession`
3. callback returns to the app via custom URL scheme or universal link
4. runtime exchanges code for tokens against `https://auth.openai.com/oauth/token`
5. runtime persists the resulting `ChatGPTSession` in Keychain
6. runtime uses the session for backend calls
7. if the session is near expiry, `ChatGPTSessionManager` refreshes before use

This keeps the Codex PKCE/token flow while replacing the desktop localhost callback transport.

## Replaced Desktop Assumptions

### Replace localhost callback server

Desktop Codex:

- binds `http://localhost:<port>/auth/callback`

iOS replacement:

- `ASWebAuthenticationSession`
- callback URL scheme or universal link

### Replace terminal device-code UX

Desktop Codex:

- prints verification URL and one-time code

iOS replacement:

- native sign-in sheet or Safari-auth session
- optional device-code fallback only if product requirements demand it

### Replace file/keyring storage policy

Desktop Codex:

- file, keyring, auto, or ephemeral

iOS replacement:

- Keychain for durable session state
- optional in-memory mode for ephemeral sessions

## Secure Storage

## Recommended default

- Keychain item containing the serialized `ChatGPTSession`
- `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`

Why:

- survives app relaunch
- stays inside normal iOS sandbox/security rules
- avoids plaintext token files

## Runtime store abstraction

`SessionSecureStoring` exists so hosts can swap storage policy if needed, but the default implementation should remain Keychain-backed.

## Session Payload

The persisted session should include only what the runtime needs:

- access token
- optional refresh token or host refresh handle
- account id
- email
- plan type
- acquisition timestamp
- optional expiry
- externally-managed flag

## Refresh Strategy

Codex’s `AuthManager` already provides the right mental model:

- use cached session if valid
- refresh when needed
- invalidate on mismatch or logout
- route external-token refresh through the host

### iOS runtime rule

The runtime should support both modes:

- a built-in PKCE code exchange for normal iOS sign-in
- host-provided refresh behavior when an app wants to fully externalize auth

For externally managed auth, it should call:

```swift
authProvider.refresh(session:reason:)
```

This matches the upstream `ExternalAuthRefresher` pattern.

## Lifecycle Restoration

On app launch:

1. `ChatGPTSessionManager.restore()`
2. load Keychain session
3. expose signed-in state to UI
4. lazily refresh on first backend use or when unauthorized

On logout:

1. clear Keychain session
2. clear runtime thread state if desired by host policy
3. notify UI immediately

## Error Handling

The iOS auth adapter should surface:

- sign-in cancelled
- callback mismatch
- token exchange failed
- refresh failed
- session missing/expired

The runtime should normalize these into user-displayable, non-transport-specific errors.

## First Prototype in This Repo

This implementation now includes:

- `ChatGPTSession`
- `ChatGPTAuthProviding`
- `SessionSecureStoring`
- `KeychainSessionSecureStore`
- `ChatGPTSessionManager`
- `ChatGPTOAuthProvider`
- `SystemChatGPTWebAuthenticationProvider`

The demo target still includes a mock auth provider for deterministic tests and previews, but the core package now also contains a real Apple-platform OAuth path.

The remaining work is live validation in a real app target:

- confirm the chosen redirect URI is registered correctly
- confirm the Codex-compatible originator value is accepted for the target app flow
- confirm refresh behavior against a real ChatGPT account session

## Bottom Line

Port the Codex auth model, not the Codex desktop login transport.

For iOS, the right mapping is:

- Codex `AuthManager` -> `ChatGPTSessionManager`
- Codex `ExternalAuthRefresher` -> host `ChatGPTAuthProviding.refresh`
- Codex file/keyring auth storage -> Keychain secure store
- Codex localhost callback flow -> `ASWebAuthenticationSession`
