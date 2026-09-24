# ChatGPT account metadata compatibility

The SDK resolves account metadata locally from tokens for browser OAuth, device-code authentication, refresh, and local Codex discovery. App-owned session restoration repairs metadata saved by alpha.31/alpha.32 without logout, reinstall, token refresh, or a metadata endpoint. The repair is saved before restoration returns and survives the next reopening. External credential stores remain read-only.

## Resolution contract

- Within each token, `https://api.openai.com/auth` supplies `chatgpt_account_id` and `chatgpt_plan_type`; `https://api.openai.com/profile` supplies email and name. Namespaced fields take precedence over corresponding legacy top-level fields.
- ID-token metadata wins over access-token metadata. Missing ID-token account ID/email/plan falls back to the access token. A present malformed or unsupported ID-token plan remains unknown, even if the access token or legacy field names a known plan. A malformed whole token contributes no metadata. Names come from the ID token.
- Conflicting resolved account IDs or ChatGPT user IDs across tokens are rejected with `ChatGPTSessionError.accountChanged`. Namespaced account IDs supersede legacy account IDs in the same token. Restoration and refresh reject a token account ID that differs from an existing non-placeholder account ID. Refresh also compares old and new ChatGPT user IDs when supplied. Email is descriptive metadata, not the workspace identity.
- Restoration fills only empty IDs/emails, `unknown-account`, `unknown@chatgpt.local`, unknown plans, and missing/blank names. Valid existing metadata, credentials, timestamps, and ownership survive unchanged. Resolving a placeholder ID establishes the real application account binding; an existing real binding is never changed. Previously bound conversations are not rewritten.
- Refresh can update metadata from new credentials for the same identity; omitted refreshed values retain valid saved metadata. An explicitly unsupported or malformed refreshed plan becomes `.unknown`, never a stale Free/paid classification. Refresh-token omission retains the existing refresh token. Saved names survive missing/blank refreshed names.
- Decoding claims is metadata extraction, not independent signature verification. Credentials must come from the selected authentication transport or trusted credential store. No tokens, claim payloads, email, or private account data are logged by this resolver.

## Plan vocabulary and source compatibility

Audited against upstream Codex checkout `4b664e0ef0397f82e68c60088a90fcd035deb796`, `codex-rs/protocol/src/auth.rs` (`KnownPlan` and `PlanType::from_raw_value`).

Existing cases remain: `free`, `plus`, `pro`, `team`, `business`, `enterprise`, `edu`, `unknown`. Alias `hc` resolves to `enterprise`; `education` resolves to `edu`. Matching ignores case and surrounding whitespace.

New distinct cases and serialized values:

| Swift case | Raw value |
| --- | --- |
| `go` | `go` |
| `proLite` | `prolite` |
| `selfServeBusinessProLite` | `self_serve_business_prolite` |
| `selfServeBusinessUsageBased` | `self_serve_business_usage_based` |
| `ent26` | `ent26` |
| `enterpriseCbpAutomation` | `enterprise_cbp_automation` |
| `enterpriseCbpUsageBased` | `enterprise_cbp_usage_based` |
| `eduPlus` | `edu_plus` |
| `eduPro` | `edu_pro` |

Missing, malformed, and unfamiliar plans remain `.unknown`. Go is not Free; Pro Lite is not Pro. The SDK infers no Free/paid classification or application eligibility from unknown values. Exhaustive host switches must handle the new cases. Older SDKs cannot decode persisted new enum values: do not downgrade after saving these plans without a host-owned migration.

## Pocket POTUS integration

Pin the fixed commit supplied with this change until an authorized release includes it; alpha.31 and alpha.32 do not include this fix. Await the existing session-manager/runtime restoration call before reading `account.plan`. No new resolver, migration call, logout, reinstall, or authentication request is needed. Continue using the SDK-owned refreshed/restored session. Update exhaustive plan switches for the cases above. Keep the Free-account product restriction and treatment of `.unknown` in Pocket POTUS; CodexKit imposes neither policy.

Offline regression tests use synthetic namespaced JWTs, concrete auth providers with URLProtocol transport fixtures, the real session manager, and unique Keychain entries. They inspect stored values after repair/refresh/reopening and verify logout deletes credentials. No live authentication or model request is required.
