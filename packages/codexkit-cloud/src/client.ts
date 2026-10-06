import { CodexKitCloudError, fail, type ErrorDetails, type ProviderOutcome } from "./errors.js";
import { isObject, parseJson, utf8 } from "./json.js";
import { resolveLimits } from "./limits.js";
import { authenticationHeaders, prepareRequest } from "./request.js";
import { providerFailure, ResponseConsumer } from "./response.js";
import { abortable, checkAbort, readEvents } from "./stream.js";
import type { CodexKitBridgeClientOptions, ExecuteInput, ExecutionLimits, ExecutionResult, PreparedRequest } from "./types.js";

export const CODEX_RESPONSES_ENDPOINT = "https://chatgpt.com/backend-api/codex/responses";
const reservedHeaders = new Set([
  "authorization", "chatgpt-account-id", "cookie", "set-cookie", "host", "content-length",
  "content-type", "accept", "accept-encoding", "connection", "transfer-encoding", "upgrade",
  "session_id", "x-client-request-id", "originator",
]);

function configure(options: CodexKitBridgeClientOptions): {
  endpoint: string; headers: Record<string, string>; limits: ExecutionLimits; fetcher: typeof fetch;
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
    return { endpoint: endpoint.href, headers, limits: resolveLimits(options.limits), fetcher };
  } catch { return fail("invalid_configuration"); }
}

function privateSafe(details: ErrorDetails, secrets: readonly string[]): ErrorDetails {
  const safe: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(details)) {
    if (key === "outcome" || typeof value !== "string" || !secrets.some(secret => secret.length > 0 && value.includes(secret))) safe[key] = value;
  }
  return safe as ErrorDetails;
}

function requestId(response: Response): string | undefined {
  const value = response.headers.get("x-request-id");
  return value && /^[A-Za-z0-9_.:-]{1,256}$/.test(value) ? value : undefined;
}

async function httpFailure(response: Response, limits: ExecutionLimits, signal: AbortSignal): Promise<CodexKitCloudError> {
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

/** Reusable backend client. Configuration is shared; credentials and execution state are per call. */
export class CodexKitBridgeClient {
  readonly #configuration: ReturnType<typeof configure>;

  constructor(options: CodexKitBridgeClientOptions = {}) {
    this.#configuration = configure(options);
  }

  /** Runs the client's configured preflight without making a provider request. */
  validatePreparedRequest(request: PreparedRequest): void {
    prepareRequest(request, this.#configuration.limits);
  }

  /** Executes one generation POST with isolated state. No implicit retries or credential refresh. */
  async execute(input: ExecuteInput): Promise<ExecutionResult> {
    const { endpoint, headers, limits, fetcher } = this.#configuration;
    const controller = new AbortController();
    const cancel = (): void => controller.abort();
    let attempted = false;
    let consumer: ResponseConsumer | undefined;
    let providerRequestId: string | undefined;
    let response: Response | undefined;
    let secrets: string[] = [];
    let callerSignal: AbortSignal | undefined;
    try {
      if (!input || (input.onProgress !== undefined && typeof input.onProgress !== "function")) fail("invalid_request");
      if (input.signal !== undefined && !(input.signal instanceof AbortSignal)) fail("invalid_request");
      callerSignal = input.signal;
      callerSignal?.addEventListener("abort", cancel, { once: true });
      if (callerSignal?.aborted) cancel();
      checkAbort(controller.signal);
      const request = prepareRequest(input.preparedRequest, limits);
      const authentication = authenticationHeaders(input.authentication);
      secrets = [input.authentication.accessToken, input.authentication.accountId, ...Object.values(headers)];
      const onProgress = input.onProgress;
      consumer = new ResponseConsumer(request, limits);
      attempted = true;
      response = await abortable(fetcher(endpoint, {
        method: "POST",
        headers: { ...headers, ...request.headers, ...authentication, "Content-Type": "application/json", Accept: "text/event-stream" },
        body: request.body,
        redirect: "manual",
        signal: controller.signal,
      }), controller.signal);
      providerRequestId = requestId(response);
      if (!response.ok) throw await httpFailure(response, limits, controller.signal);
      if (response.headers.get("content-type")?.split(";")[0]?.trim().toLowerCase() !== "text/event-stream" || !response.body) fail("invalid_response");
      for await (const event of readEvents(response.body, limits, controller.signal)) {
        checkAbort(controller.signal);
        const next = consumer.consume(event);
        if (next.result) {
          const details = privateSafe({ ...(providerRequestId ? { requestId: providerRequestId } : {}) }, secrets);
          return Object.freeze({ ...next.result, ...(details.requestId ? { requestId: details.requestId } : {}) });
        }
        if (next.progress && onProgress) {
          try { await abortable(Promise.resolve(onProgress(next.progress)), controller.signal); }
          catch { checkAbort(controller.signal); fail("progress_callback_failed"); }
        }
      }
      return fail("stream_interrupted");
    } catch (error) {
      const code = controller.signal.aborted ? "cancelled"
        : error instanceof CodexKitCloudError ? error.code : attempted ? "transport_error" : "invalid_request";
      const outcome: ProviderOutcome = attempted ? "unknown" : "not_started";
      const details: ErrorDetails = {
        outcome,
        ...consumer?.details,
        ...(providerRequestId ? { requestId: providerRequestId } : {}),
        ...(error instanceof CodexKitCloudError ? error.details : {}),
      };
      throw new CodexKitCloudError(code, privateSafe(details, secrets));
    } finally {
      callerSignal?.removeEventListener("abort", cancel);
      // Both failures and successful completion release the provider connection.
      if (response?.body && !response.body.locked) void response.body.cancel().catch(() => {});
      controller.abort();
    }
  }
}
