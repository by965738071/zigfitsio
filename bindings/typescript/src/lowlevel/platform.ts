/**
 * The C `long` chokepoint. The library ships as a single `wasm32` module where
 * C `long` is always 4 bytes, so a `long[]` is an `Int32Array` and there is no
 * LP64/LLP64 branch (the native FFI backends that made this vary were removed in
 * the WebAssembly migration). Keeping these helpers means the call sites in
 * `hdu.ts`/`hdulist.ts`/`convenience.ts` stay unchanged.
 *
 * wasm32 caps a C `long` at 32 bits; that is not a real limit here because an
 * in-memory FITS file is bounded by the 4 GiB linear-memory ceiling, so every
 * axis length / HDU index / section bound fits comfortably in an `i32`.
 */

export const LONG_BYTES = 4 as const;

/** Backing store for a C `long[]` (axes, tile shapes, section bounds). */
export type LongArray = Int32Array;

export function longArray(values: readonly number[]): LongArray {
  return Int32Array.from(values);
}

export function newLongArray(n: number): LongArray {
  return new Int32Array(n);
}

export function readLongAt(a: LongArray, i: number): number {
  return a[i];
}
