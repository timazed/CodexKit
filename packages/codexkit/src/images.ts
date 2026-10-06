import { CodexKitCloudError, fail, type ErrorDetails } from "./errors.js";
import { prepareImageRequest } from "./image-request.js";
import { decodeImageResponse, imageHTTPFailure, imageIdentifier, readImageBody } from "./image-response.js";
import { authenticationHeaders } from "./request.js";
import { abortable, checkAbort } from "./stream.js";
import { privateSafe, type configure } from "./transport.js";
import type { ExecuteImageInput, ImageExecutionResult } from "./image-types.js";

export async function executeImage(input: ExecuteImageInput, configuration: ReturnType<typeof configure>): Promise<ImageExecutionResult> {
  const { endpoint, headers, limits, imageLimits, fetcher } = configuration;
  const controller = new AbortController();
  const cancel = (): void => controller.abort();
  let callerSignal: AbortSignal | undefined, response: Response | undefined;
  let attempted = false;
  let details: ErrorDetails = {};
  let secrets: string[] = [];
  try {
    if (!input || (input.signal !== undefined && !(input.signal instanceof AbortSignal))) fail("invalid_request");
    callerSignal = input.signal;
    callerSignal?.addEventListener("abort", cancel, { once: true });
    if (callerSignal?.aborted) cancel();
    checkAbort(controller.signal);
    const request = prepareImageRequest(input.preparedRequest, imageLimits, limits);
    const authentication = authenticationHeaders(input.authentication);
    secrets = [input.authentication.accessToken, input.authentication.accountId, ...Object.values(headers)];
    // Derive only from trusted constructor configuration, never from a request-supplied URL.
    const url = new URL(endpoint);
    url.pathname = url.pathname.slice(0, -"responses".length) +
      (request.action === "generate" ? "images/generations" : "images/edits");
    attempted = true;
    const pending = fetcher(url.href, { method: "POST", redirect: "manual", signal: controller.signal,
      headers: { ...headers, ...request.headers, ...authentication, "Content-Type": "application/json", Accept: "application/json" },
      body: request.body });
    // Also release a late custom-transport response after caller cancellation.
    void pending.then(value => {
      if (controller.signal.aborted && value.body && !value.body.locked) void value.body.cancel().catch(() => {});
    }, () => {});
    response = await abortable(pending, controller.signal);
    const requestId = imageIdentifier(response.headers.get("x-request-id"), secrets);
    const imageRequestId = imageIdentifier(response.headers.get("x-codex-imagegen-request-id"), secrets);
    details = { ...(requestId ? { requestId } : {}), ...(imageRequestId ? { imageRequestId } : {}) };
    if (!response.ok) throw await imageHTTPFailure(response, limits, controller.signal);
    if (response.headers.get("content-type")?.split(";")[0]?.trim().toLowerCase() !== "application/json") fail("invalid_response");
    const bytes = await readImageBody(response, imageLimits.maxResponseBytes, controller.signal);
    checkAbort(controller.signal);
    const result = decodeImageResponse(bytes, imageLimits, limits, secrets);
    checkAbort(controller.signal);
    return Object.freeze({ status: "completed", action: request.action, clientRequestId: request.clientRequestId,
      ...(requestId ? { requestId } : {}), ...(imageRequestId ? { imageRequestId } : {}), ...result });
  } catch (error) {
    const code = controller.signal.aborted ? "cancelled" : error instanceof CodexKitCloudError ? error.code :
      attempted ? "transport_error" : "invalid_request";
    throw new CodexKitCloudError(code, privateSafe({ outcome: attempted ? "unknown" : "not_started", ...details,
      ...(error instanceof CodexKitCloudError ? error.details : {}) }, secrets));
  } finally {
    callerSignal?.removeEventListener("abort", cancel);
    if (response?.body && !response.body.locked) void response.body.cancel().catch(() => {});
    controller.abort();
  }
}
