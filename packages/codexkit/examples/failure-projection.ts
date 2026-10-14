import { sanitizeCodexFailure, type SanitizedCodexFailure } from "@timazed/codexkit";

// Illustrative mp-api projection: the application chooses its own DTO fields.
export type ProjectedCodexFailure = Pick<SanitizedCodexFailure,
  "code" | "message" | "outcome" | "httpStatus" | "requestId" | "providerReason">;

export function projectStoredFailure(stored: unknown): ProjectedCodexFailure | undefined {
  const safe = sanitizeCodexFailure(stored);
  if (!safe) return undefined; // The caller retains its application-specific fallback/code.
  return {
    code: safe.code,
    message: safe.message,
    ...(safe.outcome !== undefined ? { outcome: safe.outcome } : {}),
    ...(safe.httpStatus !== undefined ? { httpStatus: safe.httpStatus } : {}),
    ...(safe.requestId !== undefined ? { requestId: safe.requestId } : {}),
    ...(safe.providerReason !== undefined ? { providerReason: safe.providerReason } : {}),
  };
}

// requestId is always the provider request ID. Keep the API's own HTTP request ID
// in the application's separate envelope; never backfill safe.requestId with it.
