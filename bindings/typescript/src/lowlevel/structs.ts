/**
 * Codecs for the three C structs the ABI passes by pointer (never by value),
 * so neither FFI backend needs struct support: each struct is one
 * `ArrayBuffer` written/read through native-endian typed-array views (every
 * field is naturally aligned, and the C side reads native endianness).
 *
 * Layouts follow C natural alignment on 64-bit targets and are identical on
 * SysV and Win64 (all fields are fixed-width except `int`, which is 4 bytes
 * on both). Field order must match `bindings/capi/abi.zig` /
 * `bindings/c/zigfitsio.h`; the offset math is guarded by runtime tripwire
 * tests in `tests/lowlevel.test.ts`.
 */

/**
 * Open/create options (mirrors `ZfOpenOpts`, size 72). A `0`/unset limit
 * field means "use the library default"; passing `null`/`undefined` to the
 * open call means all defaults with checksums off (`abi.zig optsFrom`).
 */
export interface OpenOptions {
  checksumOnClose?: boolean;
  maxHeaderBlocks?: number;
  maxHduCount?: number;
  maxNaxisProduct?: number | bigint;
  maxHeapBytes?: number | bigint;
  maxVlaElems?: number | bigint;
  maxStringValue?: number;
  maxTileBytes?: number | bigint;
  maxOpenAlloc?: number | bigint;
  maxMatches?: number;
}

const toU64 = (v: number | bigint | undefined): bigint => (v === undefined ? 0n : BigInt(v));

/** Encode `opts` as a 72-byte ZfOpenOpts, or return null (⇒ NULL pointer, all defaults). */
export function encodeOpenOpts(opts?: OpenOptions | null): Uint8Array | null {
  if (opts == null) return null;
  const buf = new ArrayBuffer(72);
  const i32 = new Int32Array(buf); // element index = byte offset / 4
  const u32 = new Uint32Array(buf);
  const u64 = new BigUint64Array(buf); // element index = byte offset / 8
  i32[0] = opts.checksumOnClose ? 1 : 0; // @0
  u32[1] = opts.maxHeaderBlocks ?? 0; // @4
  u32[2] = opts.maxHduCount ?? 0; // @8, pad @12
  u64[2] = toU64(opts.maxNaxisProduct); // @16
  u64[3] = toU64(opts.maxHeapBytes); // @24
  u64[4] = toU64(opts.maxVlaElems); // @32
  u32[10] = opts.maxStringValue ?? 0; // @40, pad @44
  u64[6] = toU64(opts.maxTileBytes); // @48
  u64[7] = toU64(opts.maxOpenAlloc); // @56
  u32[16] = opts.maxMatches ?? 0; // @64, tail pad @68
  return new Uint8Array(buf);
}

/**
 * Per-call BSCALE/BZERO/BLANK override (mirrors `ZfScaling`, size 32).
 * `raw` exposes stored values unscaled.
 */
export interface Scaling {
  bscale?: number;
  bzero?: number;
  blank?: number | bigint;
  raw?: boolean;
}

export function encodeScaling(s: Scaling): Uint8Array {
  const buf = new ArrayBuffer(32);
  const f64 = new Float64Array(buf);
  const i64 = new BigInt64Array(buf);
  const i32 = new Int32Array(buf);
  f64[0] = s.bscale ?? 1; // @0
  f64[1] = s.bzero ?? 0; // @8
  i64[2] = s.blank === undefined ? 0n : BigInt(s.blank); // @16
  i32[6] = s.blank === undefined ? 0 : 1; // has_blank @24
  i32[7] = s.raw ? 1 : 0; // raw @28
  return new Uint8Array(buf);
}

/** Per-column metadata (mirrors `ZfColInfo`, size 64; filled by `zf_table_col_info`). */
export interface ColInfo {
  /** Natural element ZfType. */
  typecode: number;
  /** Elements per cell (bytes for 'A', bits for 'X'); -1 for VLA. */
  repeat: number;
  /** Field byte width (binary) or text width (ASCII). */
  width: number;
  isVla: boolean;
  /** Raw TFORM letter, e.g. "J". */
  tformChar: string;
  tscal: number;
  tzero: number;
  tnull: bigint;
  hasTnull: boolean;
}

export function newColInfoBuf(): Uint8Array {
  return new Uint8Array(64);
}

export function decodeColInfo(bytes: Uint8Array): ColInfo {
  const buf = bytes.buffer as ArrayBuffer;
  const off = bytes.byteOffset;
  const i32 = new Int32Array(buf, off, 16);
  const i64 = new BigInt64Array(buf, off, 8);
  const f64 = new Float64Array(buf, off, 8);
  return {
    typecode: i32[0], // @0, pad @4
    repeat: Number(i64[1]), // @8
    width: Number(i64[2]), // @16
    isVla: i32[6] !== 0, // @24
    tformChar: String.fromCharCode(i32[7]), // @28
    tscal: f64[4], // @32
    tzero: f64[5], // @40
    tnull: i64[6], // @48
    hasTnull: i32[14] !== 0, // @56, tail pad @60
  };
}
