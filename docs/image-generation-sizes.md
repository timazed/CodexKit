# Codex image size investigation — 29 September 2026

> Historical alpha.34 evidence for the Responses route. The alpha.35 default
> client uses the dedicated Images API; see [the current contract](messaging.md#standalone-image-generation).
> These live results do not validate the new endpoint.


## Finding

The Codex backend did not honor the image tool's `size` field in five controlled
live cases. This was not caused by Swift encoding, local resizing, or a mismatch
between image metadata and the actual JPEG. Each URLSession task's original
serialized request contained the intended size, and each request had exactly one
HTTP transaction. The provider's reported size matched ImageIO's decoded JPEG
dimensions.

| Action | Requested image model | Serialized size | Provider size and decoded pixels |
| --- | --- | --- | --- |
| Generate | omitted | 1024×1024 | 1312×1199 |
| Edit | omitted | 1536×1024 | 1254×1254 |
| Edit | omitted | 1024×1536 | 1254×1254 |
| Edit | omitted | 2048×2048 | 1254×1254 |
| Edit | gpt-image-1.5 | 1024×1024 | 1254×1254 |

Every case used the account-discovered main model `gpt-6-astra`, low quality,
JPEG output, and explicit image-tool selection. The edit reference was the same
512×512 synthetic portrait. Prompt text was unchanged between edit cases. The
explicit image-model case was an intentional experiment; the SDK never silently
substitutes an image model when the caller passes nil.

All five outputs contain approximately 1,572,864 pixels (1536×1024). The observed
square result, 1254×1254, contains 1,572,516 pixels; the generated 1312×1199 image
contains 1,573,088. This strongly suggests server-side normalization to about
1.57 MP, with geometry selected independently of the requested `size`. The tests
do not reveal which internal model or server stage performs that normalization,
nor establish that every quality, account, model, or future backend behaves this
way. In particular, Codex does not simply force one fixed square size: generation
returned a different aspect ratio.

The [public image API documentation](https://developers.openai.com/api/docs/guides/image-generation#customize-image-output)
documents configurable image dimensions. It does not explain this behavior of
the authenticated `/backend-api/codex/responses` route. No alternative parameter
that restores exact sizing on that route has been established. Public Image API
behavior must not be assumed to describe this Codex route.

## SDK contract

Quality is the supported request control for image fidelity. The options and demo
have no size selection; the service chooses dimensions. Format, action, and model
selection remain configurable.

- The size property and initializer argument have been removed entirely, including
  deprecated overloads. Existing source must remove `size:` and size assignments.
- Older serialized options still decode, but their obsolete size field is ignored,
  never transmitted, and omitted when encoded again.
- `AgentGeneratedImage.pixelSize` reports actual decoded output dimensions and is
  read-only. It returns nil if the bytes cannot be read as an image.
- Provider-reported size metadata remains available separately.
- The SDK does not resize, crop, substitute models, or retry automatically.

No request-side size contract is offered. The temporary exact-size guard and its
mismatch error added during investigation were removed along with the input API.

## Evidence and privacy

Seven controlled calls were made with explicit live-generation authorization:
five isolated the provider behavior in the table above; two evaluated a temporary
exact-size guard and automatic sizing. Every case made one HTTP transaction with
no automatic retry or generation deadline. An allowlisted observer captured the
actual serialized options, never credentials, prompts, input photos, full requests,
or raw streamed responses.

The temporary guard rejected a requested 1024×1024 edit when the provider returned
1254×1254; the automatic-size case returned the image successfully. These reports
describe intermediate investigative builds, not the final API. The obsolete size
probe was removed from the demo when size inputs were removed. The normal opt-in
image check still exercises low-quality JPEG editing without requesting dimensions.

Safe metadata and generated synthetic images remain in
`.build/image-generation-live/size-investigation-2026-09-29/`, partitioned into
`matrix`, `explicit-model`, and `strict-contract` directories. These build artifacts
are not committed.

## Verification

The final focused SDK suite passes 112 tests with warnings treated as errors.
Coverage includes generate/edit for every quality value with no transmitted size,
provider-selected output dimensions, conflicting provider size metadata, unchanged
image bytes, unreadable image dimensions, PNG result serialization, and obsolete
persisted size fields being excluded from requests. Streaming terminal success,
failure, incomplete responses, HTTP errors, and cancellation remain covered.

Both signed demos pass full verification: 47 macOS checks and iOS 27 simulator
adapter, streaming, cancellation, and recovery checks, including a second app
process. The source-size check covers 303 production files; the verification
harness passes 38 tests. Public API comparison against alpha.33 reports only the
intended size property and initializer removals, with no CodexKitUI API break.

The final alpha.34 package command,
`swift test --force-resolved-versions -Xswiftc -warnings-as-errors`, passed 740
main-suite tests (seven expected opt-in skips) and 17 recovery integration tests,
with zero failures. Evidence is retained in `.build/alpha34-package-tests.log`,
`.build/alpha34-macos-verification.log`, `.build/alpha34-ios-verification/`, and
`.build/alpha34-api-review/`. No additional live generation was needed for this
release validation; the earlier authorized live results are documented above.
