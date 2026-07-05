/**
 * The C `long` chokepoint. 19 of the 85 ABI functions take `long` or `long*`
 * (HDU indices, axes/tile/bounds arrays, counts). `long` is 4 bytes on
 * Windows (LLP64) and 8 bytes everywhere else (LP64) — every `long` that
 * crosses the boundary must go through this module.
 */

export const IS_LLP64: boolean = process.platform === "win32";
export const LONG_BYTES: number = IS_LLP64 ? 4 : 8;

/** Backing store for a C `long[]` (axes, tile shapes, section bounds). */
export type LongArray = Int32Array | BigInt64Array;

export function longArray(values: readonly number[]): LongArray {
  return IS_LLP64 ? Int32Array.from(values) : BigInt64Array.from(values, (v) => BigInt(v));
}

export function newLongArray(n: number): LongArray {
  return IS_LLP64 ? new Int32Array(n) : new BigInt64Array(n);
}

export function readLongAt(a: LongArray, i: number): number {
  const v = a[i];
  return typeof v === "bigint" ? Number(v) : v;
}
