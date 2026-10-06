export type ErrorCode =
  | "invalid_configuration" | "invalid_request" | "integrity_mismatch"
  | "unsupported_request" | "unsupported_schema" | "invalid_authentication"
  | "authentication_failed" | "http_error" | "transport_error"
  | "stream_interrupted" | "invalid_response" | "provider_failed"
  | "response_incomplete" | "response_refused" | "unsupported_output"
  | "invalid_output" | "schema_mismatch" | "limit_exceeded"
  | "cancelled" | "progress_callback_failed";

/** Unknown is deliberately distinct from a confirmed provider failure. Never implies permission to retry. */
export type ProviderOutcome = "not_started" | "unknown" | "failed" | "incomplete" | "completed";

export interface ErrorDetails {
  readonly outcome?: ProviderOutcome;
  readonly httpStatus?: number;
  readonly requestId?: string;
  readonly responseId?: string;
  readonly providerCode?: string;
  readonly incompleteReason?: string;
  readonly retryAfter?: string;
}

const messages: Record<ErrorCode, string> = {
  invalid_configuration: "Invalid client configuration.",
  invalid_request: "The prepared request is malformed.",
  integrity_mismatch: "The prepared request digest does not match its bytes.",
  unsupported_request: "The request is outside the supported CodexKit subset.",
  unsupported_schema: "The response schema is invalid or uses unsupported assertions.",
  invalid_authentication: "Required authentication values are missing or malformed.",
  authentication_failed: "The provider rejected authentication or account access.",
  http_error: "The provider returned an unsuccessful HTTP response.",
  transport_error: "The provider transport failed; the remote outcome may be unknown.",
  stream_interrupted: "The stream ended before successful terminal completion.",
  invalid_response: "The provider response is malformed or inconsistent.",
  provider_failed: "The provider reported a failed response.",
  response_incomplete: "The provider reported an incomplete response.",
  response_refused: "The provider refused the requested response.",
  unsupported_output: "The provider returned unsupported output or tool activity.",
  invalid_output: "The completed output is not valid JSON.",
  schema_mismatch: "The completed output does not match the prepared response schema.",
  limit_exceeded: "An execution payload or validation limit was exceeded.",
  cancelled: "Execution was cancelled by its caller.",
  progress_callback_failed: "The progress callback failed.",
};

/** Messages and serialized errors never contain request text, raw provider errors, or transport causes. */
export class CodexKitCloudError extends Error {
  readonly code: ErrorCode;
  readonly details: Readonly<ErrorDetails>;

  constructor(code: ErrorCode, details: ErrorDetails = {}) {
    super(messages[code]);
    this.name = "CodexKitCloudError";
    this.code = code;
    this.details = Object.freeze({ ...details });
  }

  toJSON(): { code: ErrorCode; message: string } & ErrorDetails {
    return { code: this.code, message: this.message, ...this.details };
  }
}

export function fail(code: ErrorCode): never { throw new CodexKitCloudError(code); }
