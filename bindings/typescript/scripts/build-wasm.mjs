#!/usr/bin/env node
/**
 * Build the single-package artifact `zigfitsio.wasm` (the wasm32-freestanding
 * C-ABI reactor) and copy it into `dist/` so it ships next to the compiled JS.
 * This one binary replaces the seven native `zigfitsio-*` platform packages.
 *
 * Env: ZIG=/path/to/zig overrides the zig binary.
 */
import { execFileSync } from "node:child_process";
import { copyFileSync, existsSync, mkdirSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const PKG_ROOT = resolve(HERE, "..");
const REPO_ROOT = resolve(PKG_ROOT, "..", "..");
const zig = process.env.ZIG ?? "zig";

console.log("[wasm] zig build wasm (ReleaseSmall, wasm32-freestanding)");
execFileSync(zig, ["build", "wasm"], { cwd: REPO_ROOT, stdio: "inherit" });

const src = join(REPO_ROOT, "zig-out", "bin", "zigfitsio.wasm");
if (!existsSync(src)) {
  console.error(`[wasm] expected artifact missing: ${src}`);
  process.exit(1);
}
const distDir = join(PKG_ROOT, "dist");
mkdirSync(distDir, { recursive: true });
const dst = join(distDir, "zigfitsio.wasm");
copyFileSync(src, dst);
console.log(`[wasm] -> ${dst}`);
