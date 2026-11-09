import { fail } from "./errors.js";
import type { ImageExecutionLimits } from "./image-types.js";

/** Validate GIF framing and bounded LZW pixel output without allocating a bitmap. */
export function inspectGIF(bytes: Buffer, limits: ImageExecutionLimits): { width: number; height: number; frames: number } {
  if (bytes.length < 14 || !["GIF87a", "GIF89a"].includes(bytes.toString("ascii", 0, 6))) fail("invalid_response");
  const width = bytes.readUInt16LE(6), height = bytes.readUInt16LE(8);
  if (!width || !height) fail("invalid_response");
  let offset = 13, frames = 0, pixels = 0, inflated = 0, blockCount = 0;
  const packed = bytes[10]!;
  const globalColors = packed & 128 ? 2 ** ((packed & 7) + 1) : 0;
  offset += globalColors * 3;
  function blocks(): Buffer {
    const parts: Buffer[] = [];
    while (offset < bytes.length) {
      if (++blockCount > 100_000) fail("limit_exceeded");
      const size = bytes[offset++]!;
      if (!size) return Buffer.concat(parts);
      if (offset + size > bytes.length) fail("invalid_response");
      parts.push(bytes.subarray(offset, offset + size)); offset += size;
    }
    return fail("invalid_response");
  }
  while (offset < bytes.length) {
    const kind = bytes[offset++]!;
    if (kind === 0x3b) {
      if (offset !== bytes.length || frames < 2) fail("invalid_response");
      return { width, height, frames };
    }
    if (kind === 0x21) {
      if (offset >= bytes.length) fail("invalid_response");
      const label = bytes[offset++]!;
      const extension = blocks();
      if (label === 0xf9 && extension.length !== 4) fail("invalid_response");
      if (label === 0x01) fail("invalid_response"); // Plain-text rendering is outside image output.
      continue;
    }
    if (kind !== 0x2c || offset + 9 > bytes.length) fail("invalid_response");
    const left = bytes.readUInt16LE(offset), top = bytes.readUInt16LE(offset + 2);
    const w = bytes.readUInt16LE(offset + 4), h = bytes.readUInt16LE(offset + 6);
    const flags = bytes[offset + 8]!;
    if (!w || !h || left + w > width || top + h > height || (flags & 0x18)) fail("invalid_response");
    offset += 9;
    const localColors = flags & 128 ? 2 ** ((flags & 7) + 1) : 0;
    offset += localColors * 3;
    if (offset >= bytes.length || !(localColors || globalColors)) fail("invalid_response");
    if (++frames > 16) fail("limit_exceeded");
    pixels += width * height; inflated += w * h;
    if (pixels > limits.maxPixels || inflated > limits.maxInflatedBytes) fail("limit_exceeded");
    const minimum = bytes[offset++]!;
    const compressed = blocks();
    validateLZW(compressed, minimum, w * h, localColors || globalColors);
  }
  return fail("invalid_response");
}

function validateLZW(data: Buffer, minimum: number, expected: number, colors: number): void {
  if (minimum < 2 || minimum > 8) fail("invalid_response");
  const clear = 1 << minimum, end = clear + 1;
  const lengths = new Uint32Array(4096), first = new Uint16Array(4096);
  for (let i = 0; i < clear; i++) { lengths[i] = 1; first[i] = i; }
  let next = end + 1, size = minimum + 1, bit = 0, previous = -1, count = 0, started = false;
  while (bit + size <= data.length * 8) {
    let code = 0;
    for (let n = 0; n < size; n++, bit++) code |= ((data[bit >> 3]! >> (bit & 7)) & 1) << n;
    if (code === clear) { next = end + 1; size = minimum + 1; previous = -1; started = true; continue; }
    if (!started) fail("invalid_response");
    if (code === end) {
      if (count !== expected || Math.ceil(bit / 8) !== data.length) fail("invalid_response");
      return;
    }
    if (code > next || code === next && previous < 0) fail("invalid_response");
    const special = code === next;
    const length = special ? lengths[previous]! + 1 : lengths[code]!;
    const initial = special ? first[previous]! : first[code]!;
    if (!length || initial >= colors || code < clear && code >= colors) fail("invalid_response");
    count += length;
    if (count > expected) fail("invalid_response");
    if (previous >= 0 && next < 4096) {
      lengths[next] = lengths[previous]! + 1;
      first[next] = first[previous]!;
      next++;
      if (next === 1 << size && size < 12) size++;
    }
    previous = code;
  }
  fail("invalid_response");
}
