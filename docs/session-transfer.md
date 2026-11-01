# Client session export and import

CodexKit's Swift client can export the current ChatGPT sign-in and adopt a supplied
session without interactive login or filesystem discovery. This is access-only
session reuse, similar to borrowing a local Mac sign-in. Your existing backend can
store and deliver the payload; CodexKit adds no registration or reviewer-login API.

```swift
// Owner's authenticated client. Does not refresh or reread external credentials.
let data = try await ownerRuntime.exportSession()
// Send data to your backend over authenticated TLS. Never log it.

// Receiving Swift client, using the normal built-in session manager.
try await clientRuntime.importSession(data)
// Create a new thread, then use the existing execution APIs.
```

Import validates before replacing the current session. A runtime configured with a
custom read-only `AgentSessionProviding` must implement `AgentSessionManaging` to
support replacement; otherwise the existing `sessionManagementUnsupported` error
applies. Import does not transfer conversation history. Existing threads remain
bound to their previous authentication identity/source.

For explicit serialization without a runtime:

```swift
let transfer = try ChatGPTSessionTransfer(session: authenticatedSession)
let data = try transfer.exportJSON()
let imported = try ChatGPTSessionTransfer.importJSON(data)
let session = try imported.validatedSession()
try await sessionManager.useSession(session)
```

## Provider support and limits

OpenAI documents copying a ChatGPT auth cache to a trusted headless machine in
[Authentication](https://learn.chatgpt.com/docs/auth#fallback-authenticate-locally-and-copy-your-auth-cache).
This establishes credential reuse across machines for that workflow, not blanket
approval or guaranteed compatibility for third-party SDKs or multi-user services.
Workspace permissions and login restrictions still apply. OpenAI recommends API
keys for automation. CodexKit uses the existing ChatGPT Codex endpoint, not the
Platform API. No provider calls or real credentials were used to implement or test
this feature.

## Version 1 wire format

UTF-8 JSON, maximum 65,536 bytes. This is a CodexKit format, **not** `auth.json` or
the native Swift `ChatGPTSession` Codable representation.

```json
{
  "version": 1,
  "provider": "chatgpt",
  "accessToken": "synthetic-example-token",
  "expiresAt": 2000000000,
  "account": {
    "id": "synthetic-account",
    "email": "owner@example.test",
    "name": "Demo Owner",
    "plan": "plus"
  }
}
```

| Field | Required | Meaning |
| --- | --- | --- |
| `version` | Yes | Integer `1`; unsupported versions fail explicitly. |
| `provider` | Yes | Exactly `chatgpt`. |
| `accessToken` | Yes | Nonempty visible ASCII without spaces, at most 32,768 UTF-8 bytes. |
| `expiresAt` | Yes | Positive integer Unix seconds, at most 253402300799; must be strictly later than the current clock. |
| `account.id` | Yes | Account/workspace ID for `ChatGPT-Account-ID`; visible ASCII without spaces, at most 1,024 bytes. |
| `account.email`, `account.name`, `account.plan` | No | Nonempty strings without ASCII control characters, at most 1,024 UTF-8 bytes each. |

Unknown keys and null optional values are rejected. Missing plan becomes `unknown`,
missing email becomes an empty Swift account email, and unknown plan names normalize
to `unknown`. Refresh tokens, ID tokens, original credential-store paths, and
conversation data are deliberately excluded. Export fails with `expiryRequired`
when the source session's expiry is unknown.

## Expiry, replacement, and verification

`ChatGPTSessionTransferError` distinguishes `malformed`, `unsupportedVersion`,
`expiryRequired`, `expired`, and `reauthenticationRequired`. Messages contain no
input values or underlying JSON decoder errors.

Validation checks the envelope's structure and declared expiry. It does not verify
JWT signatures, ownership, token claims, revocation, workspace access, or provider
acceptance. Only trust payloads received from your authenticated owner/backend
channel. A successful import is not evidence that execution will succeed.

Imported credentials are external, in-memory credentials. They do not overwrite
saved app-owned Keychain credentials. Reimport after relaunch; calling the existing
`restore()` explicitly still restores the app's saved sign-in. Sign-out discards
the imported session without logging out its owner. The client never refreshes an
imported token. Expiry requires a newly exported session; provider authentication
rejection requires explicit replacement or owner reauthentication. The built-in
text generation runner does not automatically retry generation with imported
sessions. Other pre-existing operations, custom backends, and explicit recovery
APIs retain their own policies; use `requestRetryPolicy: .disabled` where applicable.
Existing application-owned and Mac-discovered sign-in behavior is unchanged.

## Security and TypeScript compatibility

The serialized bytes contain a bearer credential. Serialization is not encryption
or a signature. Use authenticated TLS and encrypted backend storage, and never put
payload bytes or sessions into logs, telemetry, crash attachments, URLs, or user-visible
errors. Transfer/session descriptions are redacted, but explicit serialization and
credential access necessarily expose the secret to the caller. The client receiving
this payload can use its provider credentials; backend access codes do not narrow
the provider token's permissions.

This change is Swift-only. The existing TypeScript bridge does not import this
envelope automatically. After validating this schema and expiry in your existing
backend, the explicit conversion to its current `Authentication` input is:

```typescript
const authentication = {
  accessToken: payload.accessToken,
  accountId: payload.account.id,
};
// client.execute({ preparedRequest, authentication })
```

Do not pass the whole transfer object as authentication. TypeScript's existing
bridge performs no login, refresh, or implicit generation retry. The wire format
uses Unix seconds rather than Swift's native Codable date representation; a shared
synthetic fixture in `Tests/Fixtures/session-transfer/v1.json` pins the contract.

Offline verification:

```sh
swift test --filter 'SessionTransferTests|SessionRestorationRegressionTests|ExternalSessionLifecycleTests|ExternalSessionRuntimeTests'
npm run build --prefix packages/codexkit
node Tests/Verification/session_transfer_compatibility.cjs
```
