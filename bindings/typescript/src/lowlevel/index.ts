/**
 * Low-level bindings: instantiates the `zigfitsio.wasm` module once, adapts every
 * `zf_*` symbol through the WebAssembly FFI backend, and turns nonzero status
 * returns into typed `FitsError`s. Numpy-free / reshaping-free — that is the job
 * of the high-level API. Power users can call `lib.zf_*` directly.
 *
 * ## Init model
 *
 * WebAssembly instantiation is asynchronous in the browser. To keep the classic
 * fully-synchronous API on Node and Bun (where the bytes can be read off disk and
 * compiled synchronously), the module makes a **best-effort synchronous init at
 * import**; if that cannot run (browser, or no on-disk wasm), the caller must
 * `await ready()` once before using the library. After init, every `zf_*` call is
 * synchronous. `lib`/`native` are lazy proxies that throw a clear error if touched
 * before init completes.
 */
import { openWasmLibrary, type NativeFn, type NativeLibrary, type NativeResult, type WasmExports } from "../ffi/index.js";
import { wasmBytesSync, wasmSourceAsync } from "../loader.js";
import { CODE_TO_CLASS, FitsError } from "../errors.js";
import { decOut } from "../util.js";
import { PROTOS } from "./protos.js";

export * from "./constants.js";
export * from "./platform.js";
export * from "./structs.js";
export { PROTOS } from "./protos.js";

/** Options for {@link ready}. Supply `wasm` to control where the module comes from. */
export interface ReadyOptions {
  /**
   * Explicit wasm bytes or a pre-compiled `WebAssembly.Module` (browsers, bundlers, CDNs).
   * Only honored when the module has **not** already been loaded — i.e. in the browser, or on
   * Node/Bun when the on-disk wasm was not found at import. On Node/Bun the synchronous
   * import-time init has usually already loaded the bundled wasm, so this is ignored there.
   */
  wasm?: BufferSource | WebAssembly.Module;
}

let _native: NativeLibrary | null = null;
let _ready: Promise<NativeLibrary> | null = null;

/**
 * The library version string, cached the moment the module is adopted (on any init path:
 * synchronous import-time init, {@link ready}, or a direct `lowlevel.ready()`). Empty only
 * before the module has loaded (i.e. in the browser prior to `await ready()`). Re-exported
 * live as `VERSION` from the package root.
 */
export let VERSION = "";

function adopt(exports: WebAssembly.Exports): NativeLibrary {
  _native = openWasmLibrary(exports as unknown as WasmExports, PROTOS);
  VERSION = _native.fn.zf_version() as string;
  return _native;
}

// Best-effort synchronous init for Node/Bun so the library is usable without `await`. Silently
// falls through to async `ready()` in the browser (no synchronous filesystem there).
try {
  const inst = new WebAssembly.Instance(new WebAssembly.Module(wasmBytesSync()), {});
  adopt(inst.exports);
  _ready = Promise.resolve(_native!);
} catch {
  /* defer to ready() */
}

/**
 * Ensure the WebAssembly module is loaded and the ABI is callable, then resolve.
 * Idempotent and cached. Required once in the browser (and any environment without
 * a synchronous on-disk wasm); a no-op on Node/Bun where init already ran at import.
 */
export function ready(options?: ReadyOptions): Promise<NativeLibrary> {
  if (_ready) return _ready;
  _ready = (async () => {
    const provided = options?.wasm;
    const mod =
      provided instanceof WebAssembly.Module
        ? provided
        : await WebAssembly.compile((provided as BufferSource | undefined) ?? (await wasmSourceAsync()));
    const inst = await WebAssembly.instantiate(mod, {});
    return adopt(inst.exports);
  })();
  return _ready;
}

/** Whether the WebAssembly module has finished loading (so `lib`/`native` are callable). */
export function isReady(): boolean {
  return _native !== null;
}

function requireNative(): NativeLibrary {
  if (!_native) {
    throw new FitsError(
      104,
      "zigfitsio: the WebAssembly module is not loaded yet. Call `await ready()` once before using the " +
        "library (required in the browser; Node and Bun load it synchronously at import).",
    );
  }
  return _native;
}

/** The loaded library (backend + raw callables + readCString). Lazy until init completes. */
export const native: NativeLibrary = new Proxy({} as NativeLibrary, {
  get(_t, prop: string | symbol) {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    return (requireNative() as any)[prop];
  },
});

/** Adapted `zf_*` callables keyed by symbol name. Lazy until init completes. */
export const lib: Record<string, NativeFn> = new Proxy(Object.create(null) as Record<string, NativeFn>, {
  get(_t, prop: string) {
    return requireNative().fn[prop];
  },
});

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
