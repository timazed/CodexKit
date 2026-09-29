# Image generation streaming compatibility

> Historical alpha.34 evidence for the Responses route. The alpha.35 default
> client uses the dedicated Images API; see [the current contract](messaging.md#standalone-image-generation).
> These live results do not validate the new endpoint.


## Evidence and scope

The reported integration used CodexKit 2.0.0-alpha.33 at
`77b2e860998531b240bf95ef20a68bded69f85a5`, which is the base of this fix.
Both clients POST to `/backend-api/codex/responses`, but the standalone image
client had a separate request body without `instructions` or `stream`, requested
`application/json`, and decoded only a JSON `output` array. The main Responses
client sends instructions, `stream: true`, and `Accept: text/event-stream` and
decodes SSE. The old image tests accepted the divergent request with synthetic
successful JSON responses and did not assert that contract.

This establishes a request/response compatibility defect in the SDK. It does
not establish which field caused the device's HTTP 400: the original server
explanation is unavailable. The live follow-up below confirms image generation
with the original model and low-quality JPEG edit options, and records a returned
dimension mismatch.

## Implementation

- Both callers use `CodexResponsesRequestFactory` for the request envelope,
  image-detail normalization, endpoint, authorization, and streaming headers.
- `AgentImageGenerationClient` uses `CodexResponsesEventStreamClient` for one
  HTTP attempt. It does not invoke the turn runner's retry/recovery loop, add a
  generation deadline, or replace the caller's model. Network timeouts follow
  the supplied URLSession configuration.
- The standalone image request explicitly selects `tool_choice: {"type": "image_generation"}`.
  The shared chat transport retains its `auto`/`none` choices. This follows
  [OpenAI image-tool documentation](https://developers.openai.com/api/docs/guides/tools-image-generation).
  An image-specific API must request the tool, rather than permit a text-only answer.
- Model, optional image model, action, quality, and output format are
  retained. Resolving `.auto` changes only the action. `imageModel: nil` still omits
  the tool model. The options initializer configures quality without size. The
  size property and initializer argument have been removed entirely, including
  deprecated overloads. `pixelSize` reports the actual output dimensions, as
  documented in the [size investigation](image-generation-sizes.md).
- Image output is provisional until `response.completed`. A nonempty terminal
  output snapshot is authoritative; an absent or empty snapshot retains finalized
  `output_item.done` images, matching the live Codex stream.
  Failures, incomplete responses, invalid/unfinished images, previews alone,
  missing output, and EOF without completion cannot return successful images.
  Codex's stale `generating` label is accepted only for an image already finalized
  by `output_item.done`, followed by successful terminal completion; a generating
  item in a terminal snapshot alone remains invalid.
  Missing-output errors include known terminal/stream item type labels, never
  output contents or unknown provider values.
- Cancellation propagates and cancels the URLSession task. Terminal completion
  returns without waiting for the server to close the socket. Response bytes,
  events, and decoded images remain bounded.
- HTTP failures retain image-client error codes, structured provider fields,
  retry-after and request IDs. Stream failures include client request ID,
  provider request ID, response ID, and sequence metadata when available.
  HTTP error messages retain the provider explanation instead of the raw JSON
  body. The image client uses disabled logging; it does not log credentials,
  photos, prompts, or response payloads.

## Offline verification — 29 September 2026

The following focused command passed **112 tests**, with no failures and
warnings treated as errors:

```sh
swift test --force-resolved-versions -Xswiftc -warnings-as-errors \
  --filter 'AgentImageGeneration|AgentHTTPFailureTests|CodexResponses|ImageDetailNormalizationTests|StreamedCompactionTests|CompactionTransportTests|AgentRuntimeLoggingTests|ResponseGrowthTests|ClientManagedStateTests'
```

Coverage includes the reported `gpt-6-astra` / nil image model / low quality /
JPEG edit request through production construction and SSE decoding, with no size
request and actual dimensions exposed on the result;
terminal-only and item-plus-terminal output; authoritative snapshots; failed,
incomplete, malformed, missing, preview-only, and truncated output; HTTP and
transport errors without retries; and cancellation before headers, during SSE,
and during HTTP error ingestion. A held-open URLProtocol response verifies
completion without EOF and network task cleanup. SSE bytes are also delivered
in small chunks across CRLF boundaries.

`python3 Scripts/check_source_size.py` passed all 303 production files at the
600-line limit. `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s
Tests/Verification` passed all 38 harness tests. `git diff --check` passed.
The final alpha.34 package suite passed with warnings treated as errors: 740
main-suite tests (seven expected opt-in skips) and 17 recovery integration tests,
with zero failures. The log is `.build/alpha34-package-tests.log`.
The final signed demos both passed full verification: 47 macOS checks across
initial and reopened processes, plus iOS 27 simulator SQLite/Realm, streaming,
cancellation, and receipt recovery after relaunch. These checks explicitly disable
live-account access. macOS image lifecycle coverage verifies option preservation,
overlapping-request prevention, terminal-only publication, cancellation/disconnect
discarding late results, structured errors, and rejection of empty output. The iOS
chat image view and macOS image panel both display actual decoded dimensions.

The public API comparison against alpha.33 found only the intended removed size
property and initializer; CodexKitUI has no breaking API changes. Migration steps
are included in the [alpha.34 migration notes](migration.md#image-generation-alpha34).

The opt-in live check preserves the account-discovered model, nil image model,
and low-quality JPEG edit options, with no size request. It captures structured
failure/correlation metadata if rejected. The historical live checks below do
not establish which field caused the original HTTP 400.


## macOS image demo

The connected demo now has an **Images** tab with a prompt, Generate/Edit/Auto
actions, account model selection, quality, output format, reference image
picker and preview, cancellation, generated-image preview, and Save Image.
The service chooses dimensions; the preview shows the actual decoded pixel size.
The optional image-model field is empty by default and maps to `nil`. Busy state,
Stop, and disconnect are shared with the host. The demo never publishes a late
result after cancellation or disconnect.

## Opt-in macOS live check

After signing into the macOS demo with its normal browser OAuth control, the
Debug app supports a single live image edit through that same visible panel,
using the application's saved session:

```sh
.build/macos-demo/Build/Products/Debug/CodexKitMacDemo.app/Contents/MacOS/CodexKitMacDemo \
  --run-image-demo --verification-result /tmp/codexkit-image-check/report.json
```

Only run this command with explicit live-generation authorization. It requires
`gpt-6-astra` in a freshly fetched account catalog, uses the original low-quality
JPEG edit options with `imageModel: nil` and no size request, and saves a synthetic input JPEG, the
returned JPEG, and diagnostic report beside the requested report path. Success
requires terminal SDK completion and a decodable JPEG, recording its actual dimensions. The check
adds no automatic retry or generation deadline and does not change sign-in,
saved credentials, or conversations. No credential values or raw request/response
payloads are written to the report. A native Keychain access prompt, if shown,
requires the user's interaction. The app remains open on the Images tab after
the check, with the generated image or provider error visible.

## Live follow-up: completed response without an image

The first authorized macOS run on 29 September reached HTTP 200 and terminal
completion, then reported `image_generation_missing_output`
(response `resp_0a9d9e3806157e0b016abb521695e887d0a55cde6eaac3ed37`).
It used account-discovered `gpt-6-astra`, nil image model, low-quality JPEG,
1024x1024 and a synthetic JPEG edit reference. This confirmed the streaming
request was accepted, but did not validate image generation. Inspection found
the standalone request still allowed `tool_choice: "auto"`; it now explicitly
selects the image-generation tool. The first run did not retain response
contents, so its exact text/tool decision is not known.

The instrumented rerun also returned HTTP 200, and established the decoding
defect: finalized stream types included `image_generation_call` and `message`,
but `response.completed.output` was an empty array. Treating that empty array
as authoritative discarded the streamed image. The decoder now retains
finalized streamed images across an empty terminal snapshot, while still
requiring terminal success. An offline regression reproduces this exact shape.

## Live result after reconciliation fix

The final macOS edit completed successfully through the visible Images panel on
29 September 2026 (run `0BAC8290-70C5-43E0-AB01-C9E61EBD04D3`). The production
SDK returned one decodable JPEG, 249,701 bytes. Provider metadata confirmed
`status: completed`, `action: edit`, `output_format: jpeg`, and `quality: low`.
The account-discovered main model remained `gpt-6-astra`, and `imageModel` was
omitted. The app displays the edited watercolor portrait and offers Save Image.
No automatic retry was performed in any individual live check.

**Historical size discrepancy:** that investigative build requested
`size: "1024x1024"`, while the actual JPEG was **1254 × 1254** pixels. Its live
report records `generationCompleted: true` and `provider_output_options_mismatch`,
not a full pass. The final alpha.34 API removes size requests entirely and reports
actual output dimensions without resizing or model substitution. The reason the endpoint returns different dimensions remains
unconfirmed. This does not establish the cause of the original device HTTP 400.

Local evidence is saved in `.build/image-generation-live/2026-09-29/`:
`report.json` contains only safe metadata; `input.jpg` is the synthetic fixture;
`output.jpeg` is the returned image. These build artifacts are not committed.

The subsequent [controlled size investigation](image-generation-sizes.md)
confirmed this across five request variants. The final API removes size requests
entirely while keeping actual output dimensions available. Earlier live reports
describe the investigative builds, including a temporary exact-size guard.
