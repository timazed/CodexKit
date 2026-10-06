/** JSON values are used for validation only. Original request/output bytes remain authoritative. */
export type JsonValue = null | boolean | number | string | JsonValue[] | JsonObject;
export interface JsonObject { [key: string]: JsonValue }

/** A library argument, not a new cloud protocol. These values come from CodexKit preparation. */
export interface PreparedRequest {
  readonly body: Uint8Array;
  /** Lowercase hexadecimal SHA-256 of body, calculated by CodexKit. */
  readonly sha256: string;
  /** Preserve CodexKit's session_id and x-client-request-id header values. */
  readonly sessionId: string;
  readonly clientRequestId: string;
  readonly originator: string;
}

/** Resolve per execution. The library never persists or refreshes these credentials. */
export interface Authentication {
  readonly accessToken: string;
  readonly accountId: string;
}

export type ProgressEvent =
  | { readonly type: "response.created"; readonly responseId: string }
  | { readonly type: "response.output_text.delta"; readonly delta: string;
      readonly itemId?: string; readonly contentIndex?: number }
  | { readonly type: "response.reasoning_summary_text.delta"; readonly delta: string;
      readonly itemId?: string; readonly summaryIndex?: number };

export interface ExecuteInput {
  readonly preparedRequest: PreparedRequest;
  readonly authentication: Authentication;
  readonly signal?: AbortSignal;
  /** Actual, provisional provider events. Awaited for backpressure; may contain private content. */
  readonly onProgress?: (event: ProgressEvent) => void | Promise<void>;
}

export interface OutputMessage {
  readonly id?: string;
  readonly phase?: "commentary" | "final_answer";
  readonly text: string;
}

export interface ExecutionResult {
  readonly status: "completed";
  readonly responseId: string;
  readonly requestId?: string;
  readonly format: "text" | "json_schema";
  /** Final-answer text, or unphased text if no final_answer message exists. Never trimmed. */
  readonly outputText: string;
  /** All completed assistant messages in provider order, including commentary. */
  readonly messages: readonly OutputMessage[];
  /** Exact JSON data of response.completed, excluding SSE framing. Treat as private. */
  readonly completedEvent: string;
  /** Validated final output items (also covers providers omitting output from the terminal event). */
  readonly output: readonly JsonObject[];
  readonly usage?: JsonObject;
}

export interface ExecutionLimits {
  readonly maxRequestBytes: number;
  readonly maxEventBytes: number;
  readonly maxStreamBytes: number;
  readonly maxOutputBytes: number;
  readonly maxOutputItems: number;
  readonly maxJsonDepth: number;
  readonly maxJsonNodes: number;
  readonly maxValidationSteps: number;
}

export interface CodexKitBridgeClientOptions {
  /** Trusted HTTPS responses endpoint. Images use sibling images/generations and images/edits routes. */
  readonly endpoint?: string;
  /** Trusted application configuration. Cannot override authentication or transport headers. */
  readonly headers?: Readonly<Record<string, string>>;
  readonly limits?: Partial<ExecutionLimits>;
  readonly imageLimits?: Partial<import("./image-types.js").ImageExecutionLimits>;
  /** Injection boundary for offline testing or host transport. Must not add retries or redirects. */
  readonly fetch?: typeof globalThis.fetch;
}
