import { inflateSync } from "node:zlib";
import { fail } from "./errors.js";
import type { ImageExecutionLimits } from "./image-types.js";

const signature = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
const crcTable = Uint32Array.from({ length: 256 }, (_, value) => {
  for (let bit = 0; bit < 8; bit++) value = (value & 1) ? 0xedb88320 ^ (value >>> 1) : value >>> 1;
  return value >>> 0;
});
function crc(bytes: Uint8Array): number {
  let value = 0xffffffff;
  for (const byte of bytes) value = crcTable[(value ^ byte) & 255]! ^ (value >>> 8);
  return (value ^ 0xffffffff) >>> 0;
}

function paeth(left: number, above: number, corner: number): number {
  const predictor = left + above - corner;
  const a = Math.abs(predictor - left), b = Math.abs(predictor - above), c = Math.abs(predictor - corner);
  return a <= b && a <= c ? left : b <= c ? above : corner;
}

/** PNG integrity/scanline validation; preserves the original bytes and reads actual dimensions.
 * https://www.w3.org/TR/png-3/ (chunk ordering, CRC, filtering, and Adam7 passes).
 * Ancillary color profiles are preserved, not interpreted or decompressed here.
 */
export function inspectPNG(bytes: Buffer, limits: ImageExecutionLimits): { width: number; height: number } {
  if (!bytes.subarray(0, 8).equals(signature)) fail("invalid_response");
  let offset = 8, chunks = 0, width = 0, height = 0, depth = 0, color = 0, interlace = 0;
  let palette = 0, transparency = false, seenData = false, endedData = false, ended = false;
  const compressed: Buffer[] = [];
  for (; offset < bytes.length;) {
    if (++chunks > 100_000) fail("limit_exceeded");
    if (offset + 12 > bytes.length) fail("invalid_response");
    const length = bytes.readUInt32BE(offset);
    const end = offset + 12 + length;
    if (length > 0x7fffffff || end > bytes.length) fail("invalid_response");
    const kind = bytes.toString("ascii", offset + 4, offset + 8);
    const kindBytes = bytes.subarray(offset + 4, offset + 8);
    if (!kindBytes.every(byte => (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)) ||
        kindBytes[2]! > 90 || crc(bytes.subarray(offset + 4, end - 4)) !== bytes.readUInt32BE(end - 4)) fail("invalid_response");
    const data = bytes.subarray(offset + 8, end - 4);
    if (chunks === 1 && kind !== "IHDR") fail("invalid_response");
    if (kind === "IHDR") {
      if (chunks !== 1 || length !== 13) fail("invalid_response");
      width = data.readUInt32BE(0); height = data.readUInt32BE(4);
      depth = data[8]!; color = data[9]!; interlace = data[12]!;
      const depths: Record<number, readonly number[]> = { 0: [1, 2, 4, 8, 16], 2: [8, 16], 3: [1, 2, 4, 8], 4: [8, 16], 6: [8, 16] };
      if (!width || !height || width > 0x7fffffff || height > 0x7fffffff || !depths[color]?.includes(depth) ||
          data[10] !== 0 || data[11] !== 0 || interlace > 1) fail("invalid_response");
      if (width * height > limits.maxPixels) fail("limit_exceeded");
    } else if (kind === "PLTE") {
      if (palette || transparency || seenData || color === 0 || color === 4 || !length || length % 3 || length > 768 ||
          (color === 3 && length / 3 > 2 ** depth)) fail("invalid_response");
      palette = length / 3;
    } else if (kind === "tRNS") {
      if (transparency || seenData || !(color === 0 ? length === 2 : color === 2 ? length === 6 :
        color === 3 && length > 0 && length <= palette)) fail("invalid_response");
      transparency = true;
    } else if (kind === "IDAT") {
      if (endedData || (color === 3 && !palette)) fail("invalid_response");
      seenData = true;
      compressed.push(data);
    } else if (kind === "IEND") {
      if (!seenData || length || end !== bytes.length) fail("invalid_response");
      ended = true;
    } else if (kindBytes[0]! <= 90 || ["acTL", "fcTL", "fdAT"].includes(kind)) {
      fail("invalid_response");
    }
    if (seenData && kind !== "IDAT") endedData = true;
    offset = end;
  }
  if (!ended) fail("invalid_response");
  const channels = ({ 0: 1, 2: 3, 3: 1, 4: 2, 6: 4 } as Record<number, number>)[color]!;
  const passes = interlace ? [[0, 0, 8, 8], [4, 0, 8, 8], [0, 4, 4, 8], [2, 0, 4, 4],
    [0, 2, 2, 4], [1, 0, 2, 2], [0, 1, 1, 2]] : [[0, 0, 1, 1]];
  const rows = passes.map(([x, y, dx, dy]) => {
    const columns = Math.max(0, Math.ceil((width - x!) / dx!));
    const count = columns ? Math.max(0, Math.ceil((height - y!) / dy!)) : 0;
    return { columns, count, bytes: Math.ceil(columns * channels * depth / 8) };
  });
  const expected = rows.reduce((sum, row) => sum + (row.bytes + 1) * row.count, 0);
  if (!Number.isSafeInteger(expected) || expected > limits.maxInflatedBytes) fail("limit_exceeded");
  const input = Buffer.concat(compressed);
  let inflated: { buffer: Buffer; engine: { bytesWritten: number } };
  try {
    // Node's info option also reports consumed compressed bytes, detecting trailing streams.
    inflated = inflateSync(input, { maxOutputLength: expected + 1, info: true }) as unknown as typeof inflated;
  } catch { return fail("invalid_response"); }
  if (inflated.buffer.length !== expected || inflated.engine.bytesWritten !== input.length) fail("invalid_response");
  let at = 0;
  for (const row of rows) {
    let previous = Buffer.alloc(color === 3 ? row.bytes : 0);
    for (let y = 0; y < row.count; y++) {
      const filter = inflated.buffer[at++]!;
      if (filter > 4) fail("invalid_response");
      // Palette indices must resolve to actual entries, after undoing the row filter.
      if (color === 3) {
        const current = Buffer.alloc(row.bytes);
        for (let x = 0; x < row.bytes; x++) {
          const left = current[x - 1] ?? 0, above = previous[x]!, corner = previous[x - 1] ?? 0;
          const delta = filter === 0 ? 0 : filter === 1 ? left : filter === 2 ? above :
            filter === 3 ? Math.floor((left + above) / 2) : paeth(left, above, corner);
          current[x] = (inflated.buffer[at + x]! + delta) & 255;
        }
        for (let x = 0; x < row.columns; x++) {
          const value = (current[Math.floor(x * depth / 8)]! >>> (8 - depth - (x * depth % 8))) & ((1 << depth) - 1);
          if (value >= palette) fail("invalid_response");
        }
        previous = current;
      }
      at += row.bytes;
    }
  }
  return Object.freeze({ width, height });
}
