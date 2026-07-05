#!/usr/bin/env node
/** Remove `dist/` so a build never ships stale output (e.g. deleted modules). */
import { rmSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const PKG_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
rmSync(join(PKG_ROOT, "dist"), { recursive: true, force: true });
