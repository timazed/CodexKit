# Dropped prompt-cache TTL port — 2026-11-09

Disposition: close PR #37 without merging and remove TTL from release draft #41.
The feature is absent from the released SDK surface and the prepared release.
Existing automatic caching and `prompt_cache_key` behavior are unchanged.

## Investigation

The [official prompt-caching documentation](https://developers.openai.com/api/docs/guides/prompt-caching#cache-lifetime)
defines `prompt_cache_options.ttl` values `30m` and `12h` for supported public
Responses API models. That does not establish availability on CodexKit's ChatGPT
OAuth endpoint, `https://chatgpt.com/backend-api/codex/responses`.

Upstream `41cbd5b9b` encodes that same object in its core request builder. Its TTL
tests use a mock server. A fresh upstream fetch at `8703d32bd0ea5cf26768859a3dd476df906ba053`
contains no change to the relevant request builder/schema, and the app-server
turn processor still sets `prompt_cache_ttl: None`. We found no substantiated
client-side fix that enables it for the supported CodexKit backend.

Using the owner's local Codex filesystem credentials read-only:

| Probe | No TTL control | `30m` | `12h` |
| --- | --- | --- | --- |
| SDK / GPT-5.6 Sol | Expected reply | HTTP 400 | Not run |
| SDK / GPT-6.1 Sol | Expected reply | HTTP 400 | HTTP 400 |
| SDK / GPT-6 Astra | Expected reply | HTTP 400 | HTTP 400 |
| SDK / Astra, upstream-style client User-Agent prefix | Expected reply | HTTP 400 | HTTP 400 |
| Independent HTTP request / Astra, without CodexKit | HTTP 200, expected reply and completed event | HTTP 400 | HTTP 400 |

All TTL failures reported `prompt_cache_options is not supported on this model`.
An independent HTTP request with explicit `mode: implicit`, a stable cache key,
and a cacheable-length prefix also failed with that same HTTP 400. The normal
control succeeded, isolating the failure from authentication and the SDK encoder.
The client prefix tested was `codex_cli_rs/0.169.0-alpha.3`; this was not an
official CLI execution. Owner credential-content hashes were unchanged. Neither
probe refreshed credentials, used Keychain, or logged tokens/account identifiers.

The evidence demonstrates rejection on the tested account, models, and endpoint;
it does not claim the option is unavailable on every OpenAI service or account.
Switching to public API-key billing would be a separate backend feature, not a
repair to this ChatGPT-session port. Silently omitting or translating the TTL
would not deliver the requested behavior.

## Reconsideration

The rejected implementation and opt-in SDK probe remain archived on
`feature/prompt-cache-ttl` at `0f46f8138479e239de974250c2b301b365b3f019`.
Only reconsider the port after both values return real successful replies on a
supported CodexKit backend. Request acceptance alone would still not prove cache
retention or cache hits. The investigation does not add a placeholder feature or
a live credential-reading test to the release.
