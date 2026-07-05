/**
 * FFI surface. `zigfitsio` ships as a single `wasm32-freestanding` module, so
 * there is exactly one backend (WebAssembly); the module is instantiated by the
 * loader (`../loader.ts`) and adapted here via `openWasmLibrary`.
 */
export type { NativeArg, NativeFn, NativeLibrary, NativeResult, NativeType, Proto, Ptr } from "./types.js";
export { openWasmLibrary, type WasmExports } from "./wasm.js";
