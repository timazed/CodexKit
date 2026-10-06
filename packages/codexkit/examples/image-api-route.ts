import { CodexKitBridgeClient, CodexKitCloudError } from "@timazed/codexkit";
import type { Authentication, PreparedImageRequest } from "@timazed/codexkit";

const client = new CodexKitBridgeClient();

interface JsonResponse {
  status(code: number): JsonResponse;
  json(body: unknown): void;
}

/** Call after authenticating the caller and resolving that caller's credentials.
 * Forward CodexKit's original bytes and digest. The host owns persistence/retries.
 */
export async function executeCodexImageRoute(
  preparedRequest: PreparedImageRequest,
  authentication: Authentication,
  response: JsonResponse,
  signal?: AbortSignal,
): Promise<void> {
  try {
    const result = await client.executeImage({ preparedRequest, authentication, ...(signal ? { signal } : {}) });
    response.status(200).json(result);
  } catch (error) {
    if (!(error instanceof CodexKitCloudError)) throw error;
    response.status(error.details.outcome === "not_started" ? 400 : 502).json({ error: error.toJSON() });
  }
}
