/**
 * Locate and load the bundled `zigfitsio.wasm` on Node and Bun, both
 * synchronously (so the classic no-`await` API keeps working there) and
 * asynchronously (parity with the browser loader).
 *
 * Browsers use the `./loader.browser.js` variant instead — selected by the
 * package's `browser` export condition — which `fetch`es the wasm rather than
 * reading it off disk. Keep the two files' exported surface identical.
 *
 * Search order for the wasm bytes:
 *   1. `ZIGFITSIO_WASM` env var (an explicit path to the module).
 *   2. `zigfitsio.wasm` next to this file (the packaged `dist/`).
 *   3. `<repo>/zig-out/bin/zigfitsio.wasm` — a dev build (`zig build wasm`)
 *      discovered by walking parents of this file and of the working directory.
 */
import { existsSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

function candidatePaths(): string[] {
  const out: string[] = [];
  const env = process.env.ZIGFITSIO_WASM;
  if (env) out.push(env);

  const here = dirname(fileURLToPath(import.meta.url));
  out.push(join(here, "zigfitsio.wasm")); // packaged: dist/zigfitsio.wasm

  // Dev fallback: zig-out/bin/zigfitsio.wasm somewhere above this file or the cwd.
  for (const root of [here, process.cwd()]) {
    let dir = resolve(root);
    for (;;) {
      out.push(join(dir, "zig-out", "bin", "zigfitsio.wasm"));
      const parent = dirname(dir);
      if (parent === dir) break;
      dir = parent;
    }
  }
  return out;
}

/** Absolute path of the first `zigfitsio.wasm` found, or throw listing every path tried. */
export function findWasm(): string {
  const tried: string[] = [];
  for (const p of candidatePaths()) {
    tried.push(p);
    if (existsSync(p)) return p;
  }
  throw new Error(
    "could not locate zigfitsio.wasm. Build it with `zig build wasm` or set ZIGFITSIO_WASM. Searched:\n  " +
      tried.join("\n  "),
  );
}

/** Read the wasm bytes synchronously (Node/Bun). Enables the no-`await` init path. */
export function wasmBytesSync(): Uint8Array<ArrayBuffer> {
  // Copy into a fresh (non-shared) ArrayBuffer so the result satisfies `BufferSource`.
  return new Uint8Array(readFileSync(findWasm()));
}

/** Async wasm source, mirroring `loader.browser.ts` (here it is the same on-disk read). */
export function wasmSourceAsync(): Promise<BufferSource> {
  return Promise.resolve(wasmBytesSync());
}
