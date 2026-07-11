/**
 * Neutral FFI IR for the `zf_*` C ABI.
 *
 * Every `zf_*` prototype is declared once against these neutral types (see
 * `lowlevel/protos.ts`); the WebAssembly backend (`ffi/wasm.ts`) maps them onto
 * linear-memory offsets and wasm value types. Values are normalized the same way
 * regardless, so the rest of the package never branches on the runtime:
 *
 *   - `handle` / `i64` / `u64` / `usize` returns are always `bigint`
 *   - `int` / `u32` / `long` / `f32` / `f64` returns are always `number`
 *   - `cstring_ret` returns are always `string`
 *   - `void` returns are `undefined`
 */

/** Raw native pointer value. `0n` means NULL. */
export type Ptr = bigint;

export type NativeType =
  | "void"
  | "int"
  | "u32"
  | "i64"
  | "u64"
  | "f32"
  | "f64"
  /** C `long`: 4 bytes on win32 (LLP64), 8 bytes elsewhere (LP64). */
  | "long"
  /** `size_t`: 64-bit on every shipped target. */
  | "usize"
  /**
   * Opaque handle (`ZfFits*`/`ZfTable*`/`ZfFindings*`) or raw address, passed
   * as a pointer-sized unsigned integer (`bigint`). ABI-identical to a pointer
   * argument on every 64-bit target, and independent of how the backend
   * represents pointers.
   */
  | "handle"
  /** TypedArray passed as a raw pointer (in/out buffer), or `null` for NULL. */
  | "buf"
  /** NUL-terminated C string argument (`string | null`). */
  | "cstr"
  /** `const char* const*` — array of NUL-terminated strings (entries and the whole array may be null). */
  | "cstr_arr"
  /** `const char*` return value decoded to a JS string. */
  | "cstring_ret";

export interface Proto {
  readonly name: string;
  readonly returns: NativeType;
  readonly args: readonly NativeType[];
}

export type NativeArg =
  | number
  | bigint
  | string
  | null
  | ArrayBufferView
  | readonly (string | null)[];

export type NativeResult = number | bigint | string | undefined;

export type NativeFn = (...args: NativeArg[]) => NativeResult;

export interface NativeLibrary {
  readonly backend: "wasm";
  /** Adapted `zf_*` callables keyed by symbol name. */
  readonly fn: Record<string, NativeFn>;
  /**
   * Copy `len` bytes at the raw address `ptr` and decode as UTF-8. Provided for
   * the allocate-and-return ABI (`zf_read_key_longstr`) available to low-level
   * callers; the copy must happen before the matching `zf_free`. (The high-level
   * layer assembles long strings from CONTINUE cards itself and does not use it.)
   */
  readCString(ptr: Ptr, len: number): string;
  /** dlclose the library. Test-only; calling `fn` afterwards is undefined. */
  close(): void;
}
