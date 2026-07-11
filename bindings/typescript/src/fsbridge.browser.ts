/**
 * Browser variant of `fsbridge.ts`, selected by the package `browser` export
 * condition so `node:fs` / `node:zlib` never reach the browser bundle. There is
 * no filesystem in the browser: the path-based `open()` / `writeTo()` throw, and
 * consumers use the in-memory `fromBytes()` / `toBytes()` instead.
 *
 * Keep the exported surface identical to `fsbridge.ts`.
 */
import { FitsIOError } from "./errors.js";

const NO_FS =
  "zigfitsio: filesystem access is unavailable in the browser. Use fromBytes()/toBytes() with your own " +
  "fetch/File I/O instead of path-based open()/writeTo().";

export function readFile(_path: string): Uint8Array {
  throw new FitsIOError(104, NO_FS);
}

export function writeFile(_path: string, _data: Uint8Array): void {
  throw new FitsIOError(104, NO_FS);
}

export function gunzip(_data: Uint8Array): Uint8Array {
  // A browser can inflate with DecompressionStream (async); the synchronous path-based
  // open() cannot, so callers should inflate to bytes themselves and use fromBytes().
  throw new FitsIOError(104, NO_FS);
}

export function existsSync(_path: string): boolean {
  return false;
}

export function renameSync(_from: string, _to: string): void {
  throw new FitsIOError(104, NO_FS);
}

export function rmSync(_path: string): void {
  throw new FitsIOError(104, NO_FS);
}
