#!/usr/bin/env node
/**
 * npm prepack hook: produce a clean, complete tarball — recompile TS → dist/,
 * ensure the `zigfitsio.wasm` reactor is present in dist/ (build it if missing),
 * and verify version sync — so a packed tarball can never ship stale JS, omit the
 * wasm, or carry a drifted version.
 */
import { execFileSync } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const PKG_ROOT = resolve(HERE, "..");
const node = process.execPath;
const run = (file, args = []) => execFileSync(file, args, { cwd: PKG_ROOT, stdio: "inherit" });

run(node, [join(HERE, "clean-dist.mjs")]);
run(node, [join(PKG_ROOT, "node_modules", "typescript", "bin", "tsc"), "-p", "tsconfig.json"]);
if (!existsSync(join(PKG_ROOT, "dist", "index.js"))) {
  console.error("prepack: tsc produced no dist/index.js");
  process.exit(1);
}

// Build + copy the wasm (needs the zig toolchain). CI may have already placed it
// in dist/ from a build artifact, in which case this refreshes it.
run(node, [join(HERE, "build-wasm.mjs")]);
if (!existsSync(join(PKG_ROOT, "dist", "zigfitsio.wasm"))) {
  console.error("prepack: dist/zigfitsio.wasm is missing (run `zig build wasm`)");
  process.exit(1);
}

run(node, [join(HERE, "check-versions.mjs")]);
