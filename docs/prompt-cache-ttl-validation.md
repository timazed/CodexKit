# Prompt-cache TTL live validation — 2026-11-09

Status: **PR #37 is closed without merging; release PR #41 excludes TTL**.
The rejected implementation and probes remain on this branch for investigation.
Offline parity and CI do not establish service availability.

The SDK's filesystem-only opt-in test loaded the local Codex `auth.json` using
`CodexLocalSessionSource` with `.file` storage. It never accessed Keychain or
refreshed credentials. SHA-256 checks before/after confirmed the owner file was
unchanged. Tokens and account identifiers were not logged.

| Model | No TTL control | `30m` | `12h` |
| --- | --- | --- | --- |
| `gpt-5.6-sol` | Expected reply | HTTP 400 | Not run |
| `gpt-6.1-sol` | Expected reply | HTTP 400 | HTTP 400 |
| `gpt-6-astra` | Expected reply | HTTP 400 | HTTP 400 |

The provider explanation was `prompt_cache_options is not supported on this model`.
Repeating the Astra matrix with the upstream-style User-Agent prefix
`codex_cli_rs/0.169.0-alpha.3` produced the same outcome. This checks that prefix;
it is not a claim that an official CLI execution was tested.

The encoded field remains the upstream `prompt_cache_options: {ttl: "30m" | "12h"}`
from `41cbd5b9b`. These observations demonstrate rejection on this session/service;
they do not establish whether support requires a different account, rollout, model,
or future server version. Do not silently omit the option or substitute another TTL
to make the test pass.

Reproduce explicitly (ordinary CI skips this live test):

```sh
CODEXKIT_RUN_FILE_TTL_TESTS=1 CODEXKIT_LIVE_TTL_MODEL=gpt-6-astra \
  swift test --filter LiveProviderTests.testLivePromptCacheTTLUsingReadOnlyCodexFileSession
```

Both TTLs must return the expected real reply before removing the hold. Retention
or cache-hit guarantees require separate evidence even after request acceptance.

## Follow-up routing audit — 2026-11-10

Fresh upstream `5b98eaafeb341225d3724a6112a93c993cc09613` still carries the optional
TTL field in the generic core request builder. Its normal app-server turn/start
caller explicitly passes `prompt_cache_ttl: None`; the TTL regression test uses a
mock server. This establishes request plumbing, not live acceptance by the
ChatGPT-session endpoint or a working user-facing Codex TTL setting. The official
[cache-lifetime guide](https://developers.openai.com/api/docs/guides/prompt-caching#cache-lifetime)
documents the public Responses API. API-key-only availability has not been proven.

The audit also found a real compatibility gap missed initially: the account's live
model catalog advertises `use_responses_lite: true`, which upstream translates to
`x-openai-internal-codex-responses-lite: true` for HTTP, paired with
`reasoning.context: all_turns`. The Lite header without that reasoning context
fails validation. With both supplied, the no-TTL control succeeds and both TTLs
still fail with the same unsupported-model explanation. This gap deserves its own
complete compatibility port; adding the header alone is not a TTL fix.

Independent WebSocket probes used upstream's `response.create` envelope and
`OpenAI-Beta: responses_websockets=2026-02-06`. The Lite variant also supplied
`client_metadata.ws_request_header_x_openai_internal_codex_responses_lite: true`
and `reasoning.context: all_turns`, matching upstream's per-request routing.

| Transport and route / GPT-6 Astra | No TTL | `30m` | `12h` |
| --- | --- | --- | --- |
| HTTP / Lite with all-turn reasoning | Completed, expected reply | HTTP 400 | HTTP 400 |
| WebSocket / standard | Completed, expected reply | Error event, status 400 | Error event, status 400 |
| WebSocket / Lite with all-turn reasoning | Completed, expected reply | Error event, status 400 | Error event, status 400 |

Every TTL error again explained `prompt_cache_options is not supported on this model`.
Owner credential hashes remained unchanged. No token refresh, Keychain access,
credential logging, production-code change, or API-key billing switch was used.
The evidence rules out these missing routing settings and HTTP-vs-WebSocket as
fixes on the tested account/service. It does not establish global availability on
other accounts or the public API.
