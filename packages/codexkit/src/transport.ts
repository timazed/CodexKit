import { CodexKitCloudError, fail, type ErrorDetails } from "./errors.js";
import { isObject, parseJson, utf8 } from "./json.js";
import { resolveLimits } from "./limits.js";
import { resolveImageLimits } from "./image-limits.js";
import { providerFailure } from "./response.js";
import { abortable, checkAbort } from "./stream.js";
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
    if (key === "outcome" || typeof value !== "string" || !secrets.some(secret => secret.length > 0 && value.includes(secret))) safe[key] = value;
  }
  return safe as ErrorDetails;
}

export function requestId(response: Response): string | undefined {
  const value = response.headers.get("x-request-id");
  return value && /^[A-Za-z0-9_.:-]{1,256}$/.test(value) ? value : undefined;
}

export async function httpFailure(response: Response, limits: ExecutionLimits, signal: AbortSignal): Promise<CodexKitCloudError> {
  let fields: ErrorDetails = {};
  const retryAfter = response.headers.get("retry-after");
  if (retryAfter && retryAfter.length <= 128 && (/^\d+(?:\.\d+)?$/.test(retryAfter) ||
    /^[A-Za-z]{3}, \d{2} [A-Za-z]{3} \d{4} \d{2}:\d{2}:\d{2} GMT$/.test(retryAfter))) fields = { retryAfter };
  if (response.body && response.headers.get("content-type")?.toLowerCase().includes("json")) {
    const reader = response.body.getReader();
    try {
      const chunks: Uint8Array[] = [];
      let length = 0;
      while (true) {
        const next = await abortable(reader.read(), signal);
        if (next.done) break;
        length += next.value.byteLength;
        if (length > Math.min(64 * 1024, limits.maxEventBytes)) break;
        chunks.push(next.value);
      }
      if (length <= Math.min(64 * 1024, limits.maxEventBytes)) {
        const value = parseJson(utf8(Buffer.concat(chunks), "invalid_response"), limits, "invalid_response");
        fields = { ...fields, ...providerFailure(isObject(value) ? value.error : undefined) };
      }
    } catch {
      checkAbort(signal);
      // A malformed error body cannot hide the authoritative HTTP failure.
    } finally {
      void reader.cancel().catch(() => {});
      reader.releaseLock();
    }
  } else if (response.body) void response.body.cancel().catch(() => {});
  return new CodexKitCloudError(response.status === 401 || response.status === 403 ? "authentication_failed" : "http_error", {
    ...fields, httpStatus: response.status, outcome: response.status >= 400 && response.status < 500 ? "failed" : "unknown",
  });
}
