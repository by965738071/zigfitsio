/** Small shared helpers (no native dependencies). */

const encoder = new TextEncoder();
const decoder = new TextDecoder();

/** UTF-8 encode a string for a (ptr, len) ABI argument pair. */
export function enc(s: string): Uint8Array {
  return encoder.encode(s);
}

export function dec(bytes: Uint8Array): string {
  return decoder.decode(bytes);
}

/** Decode `buf[0..min(outLen, buf.length)]` from a fixed-buffer string getter. */
export function decOut(buf: Uint8Array, outLen: number | bigint): string {
  const n = Math.min(Number(outLen), buf.length);
  return decoder.decode(buf.subarray(0, n));
}

/** FNV-1a 64-bit over raw bytes — data-change fingerprint for dirty tracking. */
export function fnv1a64(bytes: Uint8Array): bigint {
  let h = 0xcbf29ce484222325n;
  const prime = 0x100000001b3n;
  const mask = 0xffffffffffffffffn;
  for (let i = 0; i < bytes.length; i++) {
    h ^= BigInt(bytes[i]);
    h = (h * prime) & mask;
  }
  return h;
}

/** The raw bytes backing any TypedArray (view over the same memory, no copy). */
export function viewBytes(a: ArrayBufferView): Uint8Array {
  return new Uint8Array(a.buffer, a.byteOffset, a.byteLength);
}
