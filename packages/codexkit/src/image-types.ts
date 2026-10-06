import type { Authentication } from "./types.js";

/** Selects a dedicated Images endpoint, never a Responses tool. */
export type ImageAction = "generate" | "edit";

/** Frozen CodexKit Images JSON and its original routing metadata. */
export interface PreparedImageRequest {
  readonly action: ImageAction;
  readonly body: Uint8Array;
  readonly sha256: string;
  readonly clientRequestId: string;
  readonly imageTurnId: string;
  readonly originator: string;
}

export interface ExecuteImageInput {
  readonly preparedRequest: PreparedImageRequest;
  readonly authentication: Authentication;
  readonly signal?: AbortSignal;
}

export interface GeneratedImage {
  /** Canonical base64 PNG bytes; no URL fetch is required. Private application data. */
  readonly base64: string;
  readonly mimeType: "image/png";
  readonly pixelSize: { readonly width: number; readonly height: number };
  readonly generationId?: string;
}

export interface ImageExecutionResult {
  readonly status: "completed";
  readonly action: ImageAction;
  /** Provider creation time in Unix seconds. */
  readonly created: number;
  readonly clientRequestId: string;
  readonly requestId?: string;
  readonly imageRequestId?: string;
  readonly images: readonly GeneratedImage[];
  readonly background?: "transparent" | "opaque" | "auto";
  readonly quality?: "auto" | "low" | "medium" | "high";
}

/** Image limits are separate from the existing text/SSE budgets. */
export interface ImageExecutionLimits {
  readonly maxRequestBytes: number;
  readonly maxResponseBytes: number;
  /** Total decoded PNG bytes in a result, or reference-image bytes in a request. */
  readonly maxImageBytes: number;
  readonly maxOutputImages: number;
  readonly maxPixels: number;
  /** Maximum inflated PNG scanline bytes per image. */
  readonly maxInflatedBytes: number;
}
