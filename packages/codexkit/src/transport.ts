import { CodexKitCloudError, fail, type ErrorDetails } from "./errors.js";
import { httpDiagnostics, readHTTPErrorBody } from "./http-diagnostics.js";
import { resolveLimits } from "./limits.js";
import { resolveImageLimits } from "./image-limits.js";
import type { CodexKitBridgeClientOptions, ExecutionLimits } from "./types.js";
import type { ImageExecutionLimits } from "./image-types.js";

export const CODEX_RESPONSES_ENDPOINT = "https://chatgpt.com/backend-api/codex/responses";
const reservedHeaders = new Set([
  "authorization", "chatgpt-account-id", "cookie", "set-cookie", "host", "content-length",
  "content-type", "accept", "accept-encoding", "connection", "transfer-encoding", "upgrade",
  "session_id", "x-client-request-id", "originator", "x-codex-image-turn-id",
]);

export function configure(options: CodexKitBridgeClientOptions): {
  endpoint: string; headers: Record<string, string>; limits: ExecutionLimits; imageLimits: ImageExecutionLimits; fetcher: typeof fetch;
} {
  try {
    const endpoint = new URL(options.endpoint ?? CODEX_RESPONSES_ENDPOINT);
    if (endpoint.protocol !== "https:" || endpoint.username || endpoint.password || endpoint.search || endpoint.hash ||
      !endpoint.pathname.endsWith("/responses")) fail("invalid_configuration");
    const headers: Record<string, string> = Object.create(null) as Record<string, string>;
    for (const [name, value] of Object.entries(options.headers ?? {})) {
      const key = name.toLowerCase();
      if (!/^[!#$%&'*+.^_`|~a-z0-9-]+$/.test(key) || reservedHeaders.has(key) || key.startsWith("proxy-") ||
        typeof value !== "string" || value.length > 8192 || !/^[\x20-\x7e]*$/.test(value)) fail("invalid_configuration");
      headers[key] = value;
    }
    const fetcher = options.fetch ?? globalThis.fetch;
    if (typeof fetcher !== "function") fail("invalid_configuration");
    return { endpoint: endpoint.href, headers, limits: resolveLimits(options.limits), imageLimits: resolveImageLimits(options.imageLimits), fetcher };
  } catch { return fail("invalid_configuration"); }
}

export function privateSafe(details: ErrorDetails, secrets: readonly string[]): ErrorDetails {
  const safe: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(details)) {
    if (key === "outcome" || key === "providerReason" || typeof value !== "string" ||
        !secrets.some(secret => secret.length > 0 && value.includes(secret))) safe[key] = value;
  }
  return safe as ErrorDetails;
}

export function requestId(response: Response): string | undefined {
  const value = response.headers.get("x-request-id");
  return value && /^[A-Za-z0-9_.:-]{1,256}$/.test(value) ? value : undefined;
}

export async function httpFailure(response: Response, limits: ExecutionLimits, signal: AbortSignal): Promise<CodexKitCloudError> {
  const fields = httpDiagnostics(response, await readHTTPErrorBody(response, limits, signal));
  return new CodexKitCloudError(response.status === 401 || response.status === 403 ? "authentication_failed" : "http_error", {
    ...fields, httpStatus: response.status, outcome: response.status >= 400 && response.status < 500 ? "failed" : "unknown",
  });
}
