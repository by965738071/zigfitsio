/**
 * Dtype <-> FITS/ZfType mapping helpers (mirror of Python `_dtypes.py` plus
 * the maps at the top of `core.py`).
 *
 * TypedArrays are always native-endian and the C ABI exchanges native-endian
 * converted values, so no byte-order handling exists anywhere in this layer
 * (the Python `_native()` coercion has no TS equivalent). Complex values are
 * represented as interleaved Float32Array/Float64Array (re, im, re, im, …).
 */
import * as ll from "./lowlevel/index.js";
import { FitsStructError, FitsTypeError } from "./errors.js";

export type TypedArray =
  | Uint8Array
  | Int8Array
  | Int16Array
  | Uint16Array
  | Int32Array
  | Uint32Array
  | BigInt64Array
  | BigUint64Array
  | Float32Array
  | Float64Array;

/** numpy-style dtype tokens. c8/c16 are interleaved f4/f8 pairs. */
export type Dtype = "u1" | "i1" | "i2" | "u2" | "i4" | "u4" | "i8" | "u8" | "f4" | "f8" | "c8" | "c16";

interface DtypeInfo {
  readonly ctor: new (n: number) => TypedArray;
  readonly zf: number;
  readonly itemBytes: number;
  readonly bigint: boolean;
}

const DTYPES: Record<Dtype, DtypeInfo> = {
  u1: { ctor: Uint8Array, zf: ll.ZF_UINT8, itemBytes: 1, bigint: false },
  i1: { ctor: Int8Array, zf: ll.ZF_INT8, itemBytes: 1, bigint: false },
  i2: { ctor: Int16Array, zf: ll.ZF_INT16, itemBytes: 2, bigint: false },
  u2: { ctor: Uint16Array, zf: ll.ZF_UINT16, itemBytes: 2, bigint: false },
  i4: { ctor: Int32Array, zf: ll.ZF_INT32, itemBytes: 4, bigint: false },
  u4: { ctor: Uint32Array, zf: ll.ZF_UINT32, itemBytes: 4, bigint: false },
  i8: { ctor: BigInt64Array, zf: ll.ZF_INT64, itemBytes: 8, bigint: true },
  u8: { ctor: BigUint64Array, zf: ll.ZF_UINT64, itemBytes: 8, bigint: true },
  f4: { ctor: Float32Array, zf: ll.ZF_FLOAT32, itemBytes: 4, bigint: false },
  f8: { ctor: Float64Array, zf: ll.ZF_FLOAT64, itemBytes: 8, bigint: false },
  // Interleaved float pairs; the zf code is the matching float element code
  // (the ABI transfers 2 float slots per complex element).
  c8: { ctor: Float32Array, zf: ll.ZF_FLOAT32, itemBytes: 8, bigint: false },
  c16: { ctor: Float64Array, zf: ll.ZF_FLOAT64, itemBytes: 16, bigint: false },
};

export const isComplexDtype = (d: Dtype): boolean => d === "c8" || d === "c16";
export const isIntegerDtype = (d: Dtype): boolean =>
  d === "u1" || d === "i1" || d === "i2" || d === "u2" || d === "i4" || d === "u4" || d === "i8" || d === "u8";
export const isUnsignedDtype = (d: Dtype): boolean => d === "u1" || d === "u2" || d === "u4" || d === "u8";
export const usesBigInt = (d: Dtype): boolean => DTYPES[d].bigint;
export const itemBytes = (d: Dtype): number => DTYPES[d].itemBytes;

/** ZfType element code for a dtype (the transfer buffer's element type). */
export function zfCode(d: Dtype): number {
  return DTYPES[d].zf;
}

/** Allocate a TypedArray holding `n` elements of `d` (2n floats for complex). */
export function allocDtype(d: Dtype, n: number): TypedArray {
  return new DTYPES[d].ctor(isComplexDtype(d) ? n * 2 : n);
}

/** The dtype of a plain TypedArray (never complex — callers track that separately). */
export function dtypeOf(a: TypedArray): Dtype {
  if (a instanceof Uint8Array) return "u1";
  if (a instanceof Int8Array) return "i1";
  if (a instanceof Int16Array) return "i2";
  if (a instanceof Uint16Array) return "u2";
  if (a instanceof Int32Array) return "i4";
  if (a instanceof Uint32Array) return "u4";
  if (a instanceof BigInt64Array) return "i8";
  if (a instanceof BigUint64Array) return "u8";
  if (a instanceof Float32Array) return "f4";
  if (a instanceof Float64Array) return "f8";
  throw new FitsTypeError(410, `unsupported array type ${(a as object).constructor?.name}`);
}

// ── BITPIX ↔ dtype ──
const BITPIX_TO_DTYPE: Record<number, Dtype> = { 8: "u1", 16: "i2", 32: "i4", 64: "i8", "-32": "f4", "-64": "f8" };
const DTYPE_TO_BITPIX: Partial<Record<Dtype, number>> = { u1: 8, i2: 16, i4: 32, i8: 64, f4: -32, f8: -64 };

export function bitpixToDtype(bitpix: number): Dtype {
  const d = BITPIX_TO_DTYPE[bitpix];
  if (d === undefined) throw new FitsStructError(211, `invalid BITPIX ${bitpix}`);
  return d;
}

export function dtypeToBitpix(d: Dtype): number {
  const b = DTYPE_TO_BITPIX[d];
  if (b === undefined) throw new FitsTypeError(410, `dtype ${d} has no FITS BITPIX`);
  return b;
}

/** ZfType element code -> read dtype (inverse map; logical/bit read as 0/1 bytes). */
const ZF_TO_DTYPE: Record<number, Dtype> = {
  [ll.ZF_UINT8]: "u1",
  [ll.ZF_INT8]: "i1",
  [ll.ZF_INT16]: "i2",
  [ll.ZF_UINT16]: "u2",
  [ll.ZF_INT32]: "i4",
  [ll.ZF_UINT32]: "u4",
  [ll.ZF_INT64]: "i8",
  [ll.ZF_UINT64]: "u8",
  [ll.ZF_FLOAT32]: "f4",
  [ll.ZF_FLOAT64]: "f8",
  [ll.ZF_COMPLEX64]: "c8",
  [ll.ZF_COMPLEX128]: "c16",
  [ll.ZF_BOOL]: "u1",
  [ll.ZF_BIT]: "u1",
};

export function zfToDtype(code: number): Dtype {
  const d = ZF_TO_DTYPE[code];
  if (d === undefined) throw new FitsTypeError(410, `unsupported ZfType code ${code}`);
  return d;
}

// ── Unsigned-integer conventions ──

/** BZERO values that encode the unsigned convention for each signed image BITPIX. */
export const UNSIGNED_BZERO: Record<number, number> = { 16: 32768, 32: 2147483648, 64: 9223372036854775808 };
export const UNSIGNED_DTYPE: Record<number, Dtype> = { 16: "u2", 32: "u4", 64: "u8" };

export interface UnsignedImgPlan {
  bitpix: number;
  /** Exact as an IEEE double for all three widths (incl. 2^63). */
  bzero: number;
  storedDtype: Dtype;
}

/** Write plan for a u2/u4/u8 image via the BZERO convention, else null. */
export function unsignedImgPlan(d: Dtype): UnsignedImgPlan | null {
  if (d === "u2") return { bitpix: 16, bzero: 32768, storedDtype: "i2" };
  if (d === "u4") return { bitpix: 32, bzero: 2147483648, storedDtype: "i4" };
  if (d === "u8") return { bitpix: 64, bzero: 9223372036854775808, storedDtype: "i8" };
  return null;
}

/** Table unsigned convention: (signed on-disk dtype, TZERO) -> unsigned dtype. */
export function unsignedColDtype(elem: Dtype, tzero: number): Dtype | null {
  if (elem === "i2" && tzero === 32768) return "u2";
  if (elem === "i4" && tzero === 2147483648) return "u4";
  if (elem === "i8" && tzero === 9223372036854775808) return "u8";
  return null;
}

/** (array element bytes, signed TFORM letter) -> TZERO for an unsigned column. */
export function unsignedColTzero(d: Dtype, letter: string): number | null {
  if (d === "u2" && letter === "I") return 32768;
  if (d === "u4" && letter === "J") return 2147483648;
  if (d === "u8" && letter === "K") return 9223372036854775808;
  return null;
}

// ── Binary-table TFORM letters ──
const TFORM_BIN: Record<string, { dtype: Dtype; isComplex: boolean }> = {
  L: { dtype: "u1", isComplex: false }, // logical (0/1)
  X: { dtype: "u1", isComplex: false }, // bit -> one byte per bit element
  B: { dtype: "u1", isComplex: false },
  I: { dtype: "i2", isComplex: false },
  J: { dtype: "i4", isComplex: false },
  K: { dtype: "i8", isComplex: false },
  E: { dtype: "f4", isComplex: false },
  D: { dtype: "f8", isComplex: false },
  C: { dtype: "f4", isComplex: true },
  M: { dtype: "f8", isComplex: true },
};

/** (element dtype, is_complex) for a binary-table TFORM letter (f8 fallback). */
export function binElemDtype(letter: string): { dtype: Dtype; isComplex: boolean } {
  return TFORM_BIN[letter] ?? { dtype: "f8", isComplex: false };
}

/**
 * Element dtype -> binary-table TFORM letter (the inverse of TFORM_BIN, for
 * synthesizing a format from column data). Unsigned integers map to the signed
 * letter of matching width; the write path re-applies the TZEROn convention
 * (see unsignedColTzero) so the column still round-trips as unsigned. A
 * logical/bit column reads back as u1, so its synthesized letter is 'B';
 * tformInterchangeable keeps the file column's own 'L'/'X' on reconstruction.
 */
export const DTYPE_TO_TFORM: Record<Dtype, string> = {
  u1: "B", i1: "B", i2: "I", u2: "I", i4: "J", u4: "J",
  i8: "K", u8: "K", f4: "E", f8: "D", c8: "C", c16: "M",
};

/** ZfType element code -> binary-table TFORM letter (for rebuilding formats on copy). */
export const ZF_TO_TFORM: Record<number, string> = {
  [ll.ZF_BOOL]: "L",
  [ll.ZF_BIT]: "X",
  [ll.ZF_UINT8]: "B",
  [ll.ZF_INT8]: "B",
  [ll.ZF_INT16]: "I",
  [ll.ZF_INT32]: "J",
  [ll.ZF_INT64]: "K",
  [ll.ZF_UINT16]: "I", // unsigned via signed letter + TZERO
  [ll.ZF_UINT32]: "J",
  [ll.ZF_UINT64]: "K",
  [ll.ZF_FLOAT32]: "E",
  [ll.ZF_FLOAT64]: "D",
  [ll.ZF_COMPLEX64]: "C",
  [ll.ZF_COMPLEX128]: "M",
};
