#!/usr/bin/env node
/**
 * npm prepack hook: compile TS -> dist/ and verify version sync, so a packed
 * tarball can never ship stale JS or a drifted version.
 */
import { execFileSync } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const PKG_ROOT = resolve(HERE, "..");

execFileSync(process.execPath, [join(PKG_ROOT, "node_modules", "typescript", "bin", "tsc"), "-p", "tsconfig.json"], {
  cwd: PKG_ROOT,
  stdio: "inherit",
});
if (!existsSync(join(PKG_ROOT, "dist", "index.js"))) {
  console.error("prepack: tsc produced no dist/index.js");
  process.exit(1);
}
execFileSync(process.execPath, [join(HERE, "check-versions.mjs")], { stdio: "inherit" });
