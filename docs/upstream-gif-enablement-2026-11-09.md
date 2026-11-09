# Native GIF enablement investigation — 9 November 2026

Native GIF generation is not verified for release. Both the signed CodexKit demo
and the official Codex client return HTTP 400 with:

```text
GIF output is not enabled for this request.
```

The GIF PR remains a draft until native generation succeeds. Local animation
fixtures establish playback/export behavior only, not provider generation.

## What the upstream flag does

Audited local `codex-src` at `6107b9886`, including GIF change `f9e7b19df`:

- `codex-rs/features/src/lib.rs` declares `image_generation_animation` as
  `UnderDevelopment`, disabled by default.
- `ext/image-generation/src/extension.rs` passes that flag into the image tool.
- `ext/image-generation/src/tool.rs` exposes the model-facing `gif` option only
  when enabled and otherwise rejects it before an HTTP request.
- `codex-api/src/images.rs` serializes GIF as `output_format: "gif"` plus optional
  sibling `frame_count` and `frame_duration_ms`. It sends no body enablement flag.
- `ext/image-generation/src/backend.rs:image_request_headers` adds the image turn
  ID, optional originator, and optional `x-codex-turn-metadata`. There is no
  dedicated GIF-enabling header in this path.
- `login/src/auth/default_client.rs` supplies the standard User-Agent/originator.
  OAuth client ID and requested scopes match CodexKit's browser sign-in.
- `core/src/session/mod.rs:build_model_client_beta_features_header` advertises
  experimental-menu features to Responses. `UnderDevelopment` features have no
  experimental-menu description, so this does not advertise the GIF flag; the
  Images backend does not use that Responses header builder either.

Thus enabling the local flag permits the client to request GIF output; it does
not establish that the service will accept it. The backend's feature-enablement
implementation is not in this client repository, so its exact rollout or
eligibility rule cannot be determined from `codex-src` alone.

## Live comparisons

| Client/request | Result |
| --- | --- |
| Signed demo, native GIF with two 200 ms frames | HTTP 400, GIF not enabled |
| Signed demo, same request plus `x-codex-beta-features: image_generation_animation` | Same HTTP 400 |
| Official `0.169.0-alpha.3`, GIF flag enabled, two 200 ms frames | Same HTTP 400 |
| Official `0.169.0-alpha.3`, GIF flag enabled, `gif: {}` service defaults | Same HTTP 400 |

The installed `0.167.0-alpha.3.2` client does not recognize the GIF feature flag.
The comparison used the official newer macOS binary and its matching code-mode
host downloaded from [the upstream prerelease](https://github.com/openai/codex/releases/tag/rust-v0.169.0-alpha.3)
into the ignored `.build/gif-investigation/official/` directory. The installed
client was not replaced. Native tests used the existing Codex login; the demo
used its existing saved session. No claim is made that those login bindings are
identical.

The official client's actual `codex_core::tools::router` error log, not merely its
final model message, confirms the image service's HTTP rejection. Tests allowed
one imagegen invocation each, with unrelated tools disabled and no local drawing,
frame assembly, image-generation retries, or PNG substitution.

Local evidence (ignored build artifacts):

- `.build/gif-demo-live/generate/report.json`
- `.build/gif-investigation/beta/report.json`
- `.build/gif-investigation/official-native/stderr.log`
- `.build/gif-investigation/official-native/summary.txt`
- `.build/gif-investigation/official-defaults/stderr.log`
- `.build/gif-investigation/official-defaults/summary.txt`

The ineffective beta header was a temporary Debug probe and is not enabled in
the shipping request builder. The existing flat HTTP fields remain aligned with
upstream. Native GIF generation in the demo still requires a successful service
request; client flags and passing offline tests do not satisfy that gate.
