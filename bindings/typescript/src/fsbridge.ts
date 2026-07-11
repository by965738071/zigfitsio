/**
 * Filesystem bridge (Node/Bun). Every path-based file operation in the
 * high-level API funnels through this one module so the browser build can swap
 * it — via the package `browser` export condition — for `fsbridge.browser.ts`,
 * which throws. That keeps `node:fs` out of the browser bundle; in the browser
 * use the in-memory APIs (`fromBytes()` / `toBytes()`) instead of the path-based
 * `open()` / `writeTo()`.
 *
 * The wasm module itself never touches the filesystem (it is
 * `wasm32-freestanding`): these helpers read/write the FITS bytes on the JS side
 * and hand them to the in-memory `zf_open_memory` / `zf_read_bytes` ABI.
 */
import { existsSync as _existsSync, readFileSync, renameSync as _renameSync, rmSync as _rmSync, writeFileSync } from "node:fs";
import { gunzipSync } from "node:zlib";

/** Read a file into a fresh `Uint8Array`. */
export function readFile(path: string): Uint8Array {
  return new Uint8Array(readFileSync(path));
}

/**
 * Inflate whole-file gzip (`*.fits.gz`) bytes. The wasm module's own gzip inflate
 * is an excluded OS leaf, so `.gz` decompression happens here on the JS side (like
 * file reads) and the plain FITS bytes go to `zf_open_memory`.
 */
export function gunzip(data: Uint8Array): Uint8Array {
  return new Uint8Array(gunzipSync(data));
}

/** Write bytes to a file (overwriting). */
export function writeFile(path: string, data: Uint8Array): void {
  writeFileSync(path, data);
}

export function existsSync(path: string): boolean {
  return _existsSync(path);
}

export function renameSync(from: string, to: string): void {
  _renameSync(from, to);
}

export function rmSync(path: string): void {
  _rmSync(path);
}
