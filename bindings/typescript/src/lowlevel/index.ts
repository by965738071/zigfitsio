/**
 * Low-level bindings: loads the shared library once, adapts every `zf_*`
 * symbol through the active FFI backend, and turns nonzero status returns
 * into typed `FitsError`s. Numpy-free / reshaping-free — that is the job of
 * the high-level API. Power users can call `lib.zf_*` directly.
 */
import { openNativeLibrary, type NativeLibrary, type NativeResult } from "../ffi/index.js";
import { findLibrary } from "../loader.js";
import { CODE_TO_CLASS, FitsError } from "../errors.js";
import { decOut } from "../util.js";
import { PROTOS } from "./protos.js";

export * from "./constants.js";
export * from "./platform.js";
export * from "./structs.js";
export { PROTOS } from "./protos.js";

/** The loaded library (backend + raw callables + readCString). */
export const native: NativeLibrary = openNativeLibrary(findLibrary(), PROTOS);

/** Adapted `zf_*` callables keyed by symbol name. */
export const lib = native.fn;

/** Read the thread-local last-error message set by the most recent failing call. */
export function lastErrorMessage(): string {
  const buf = new Uint8Array(256);
  const outLen = new BigUint64Array(1);
  lib.zf_errmsg(buf, 256, outLen);
  return decOut(buf, outLen[0]);
}

/** Throw the mapped `FitsError` subclass if `status` is nonzero; else return it. */
export function check(status: NativeResult): number {
  const s = Number(status);
  if (s !== 0) {
    const Cls = CODE_TO_CLASS.get(s) ?? FitsError;
    throw new Cls(s, lastErrorMessage());
  }
  return s;
}

/** The library version string. */
export function version(): string {
  return lib.zf_version() as string;
}

// ── Tiny out-param scratch constructors ──
export const outI32 = (): Int32Array => new Int32Array(1);
export const outI64 = (): BigInt64Array => new BigInt64Array(1);
export const outU64 = (): BigUint64Array => new BigUint64Array(1);
export const outF64 = (): Float64Array => new Float64Array(1);
