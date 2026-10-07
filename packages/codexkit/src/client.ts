import { CodexKitCloudError, fail, type ErrorDetails, type ProviderOutcome } from "./errors.js";
import { authenticationHeaders, prepareRequest } from "./request.js";
import { ResponseConsumer } from "./response.js";
import { abortable, checkAbort, readEvents } from "./stream.js";
import { configure, httpFailure, privateSafe, requestId } from "./transport.js";
import { executeImage } from "./images.js";
import { prepareImageRequest } from "./image-request.js";
import type { CodexKitBridgeClientOptions, ExecuteInput, ExecutionResult, PreparedRequest } from "./types.js";
import type { ExecuteImageInput, ImageExecutionResult, PreparedImageRequest } from "./image-types.js";

export { CODEX_RESPONSES_ENDPOINT } from "./transport.js";

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

  /** Preflight for the dedicated generation/edit endpoints; never transmits. */
  validatePreparedImageRequest(request: PreparedImageRequest): void {
    prepareImageRequest(request, this.#configuration.imageLimits, this.#configuration.limits);
  }

  /** Executes a prepared Images request once and returns complete PNG results. */
  executeImage(input: ExecuteImageInput): Promise<ImageExecutionResult> {
    return executeImage(input, this.#configuration);
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
      // Codex can omit MIME metadata; the SSE parser still requires valid events and terminal completion.
      const contentType = response.headers.get("content-type");
      if ((contentType != null && contentType.split(";")[0]?.trim().toLowerCase() !== "text/event-stream") || !response.body) fail("invalid_response");
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
