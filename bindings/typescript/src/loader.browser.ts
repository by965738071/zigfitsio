/**
 * Browser variant of `loader.ts`, selected by the package `browser` export
 * condition so no `node:*` module reaches the browser bundle. There is no
 * synchronous filesystem here, so init is async: `wasmSourceAsync` fetches the
 * `zigfitsio.wasm` that sits next to this module (bundlers rewrite the
 * `new URL(..., import.meta.url)` asset reference). Callers that host the wasm
 * elsewhere can bypass this entirely via `ready({ wasm })`.
 *
 * Keep the exported surface identical to `loader.ts`.
 */

/** No synchronous wasm in the browser — throwing here makes the import-time init fall through to `ready()`. */
export function wasmBytesSync(): Uint8Array<ArrayBuffer> {
  throw new Error("zigfitsio: synchronous wasm loading is unavailable in the browser; call `await ready()`.");
}

/** Fetch the co-located `zigfitsio.wasm` as an ArrayBuffer for `WebAssembly.compile`. */
export async function wasmSourceAsync(): Promise<BufferSource> {
  const url = new URL("./zigfitsio.wasm", import.meta.url);
  const resp = await fetch(url);
  if (!resp.ok) throw new Error(`zigfitsio: failed to fetch ${url.href} (${resp.status} ${resp.statusText})`);
  return await resp.arrayBuffer();
}

/** The URL the wasm is fetched from (parity with `loader.ts`'s `findWasm`). */
export function findWasm(): string {
  return new URL("./zigfitsio.wasm", import.meta.url).href;
}
