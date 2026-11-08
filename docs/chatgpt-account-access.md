# ChatGPT sign-in, account access, and usage

[Documentation index](index.md) · [CodexKit](../README.md)

CodexKit lets users sign in with ChatGPT to power the AI experience inside your app. The built-in backend uses that signed-in session rather than a developer's OpenAI API key. Users do not need to create or paste an API key, and this path does not require developer-funded OpenAI API usage.

## What the account provides

Access remains subject to the account's eligibility, available models, usage limits, and provider controls. Do not describe the integration as free, unlimited, or available to every ChatGPT account. Your own hosting, storage, and third-party tool costs remain separate.

The SDK can discover models and expose reported usage-limit snapshots. A bundled model identifier is not evidence that the signed-in account can use that model. See [model configuration](backend-configuration.md) and [usage telemetry](usage-telemetry.md).

## How sign-in works

On iOS, the recommended flow is device-code sign-in: the app displays a verification URL and code, the user completes provider authentication, and the SDK acquires and persists a session. The app does not collect the user's ChatGPT password. Browser OAuth is also implemented; its callback acceptance depends on the provider. macOS can optionally reuse an accessible local Codex session.

The default integration stores tokens in `KeychainSessionSecureStore` and coordinates refresh through the session manager. Conversation storage is separate. Your app controls when to sign in or sign out and how to present prompts. Avoid logging credentials, and give users clear account and data controls.

See [iOS authentication](auth-on-ios.md), [macOS session reuse](auth-on-macos.md), and [session transfer](session-transfer.md) for implementation details. Session transfer is opt-in; it is not needed for the normal local integration.

## Provider interfaces and compatibility

The built-in backend targets `https://chatgpt.com/backend-api/codex` and implements Codex-compatible account authentication. This is distinct from integrating a developer API key with the public OpenAI API. CodexKit is an independent SDK, not an official OpenAI SDK.

The repository's implementation and tests demonstrate implemented behavior; they do not establish a provider guarantee for third-party account integrations or App Store acceptance. Before distributing an app, verify the provider's current support and terms for your intended integration and the platform's applicable requirements. This guide does not claim blanket authorization or a particular account entitlement.

Changes to authentication endpoints, client acceptance, redirect rules, token formats, model access, or response protocols can require SDK updates. Surface sign-in failures, expired access, and usage limits clearly. Do not silently substitute a developer-paid API path without an explicit product decision.

## Data boundaries

Prompts, selected context, attachments, and tool results used in a model request are transmitted to the provider. Local conversation persistence and optional local memory do not imply local inference or automatic access to the user's ChatGPT history. Explain these boundaries in your app's own privacy and account experience.
