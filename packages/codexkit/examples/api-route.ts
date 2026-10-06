import { CodexKitBridgeClient, CodexKitCloudError } from "@timazed/codexkit";
import type { Authentication, PreparedRequest } from "@timazed/codexkit";

const client = new CodexKitBridgeClient();

/** Compatible with common framework response objects; no framework dependency. */
interface JsonResponse {
  status(code: number): JsonResponse;
  json(body: unknown): void;
}

/**
 * Call from your authenticated route after parsing the CodexKit payload and
 * resolving credentials belonging to that caller. Authentication is supplied
 * separately, never extracted from arbitrary provider headers in the request.
 */
export async function executeCodexRoute(
  preparedRequest: PreparedRequest,
  authentication: Authentication,
  response: JsonResponse,
): Promise<void> {
  try {
    const result = await client.execute({ preparedRequest, authentication });
    response.status(200).json(result);
  } catch (error) {
    if (!(error instanceof CodexKitCloudError)) throw error;
    // Example HTTP mapping only; the API team owns its route contract.
    const status = error.details.outcome === "not_started" ? 400 : 502;
    response.status(status).json({ error: error.toJSON() });
  }
}
