# Prompt-cache TTL live validation — 2026-11-09

Status: **hold PR #37 and the combined release draft #41**. Offline parity and CI
do not establish service availability.

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
