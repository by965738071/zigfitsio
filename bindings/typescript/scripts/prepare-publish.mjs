#!/usr/bin/env node
/**
 * Inject the @zigfitsio/* platform packages as exact-version
 * optionalDependencies into package.json. Run ONLY right before `npm publish`
 * (CI publish job, or a manual bootstrap release): the committed package.json
 * deliberately omits them so `npm install` works before the platform packages
 * exist on the registry (and during version bumps).
 *
 * The platform list is derived from the built npm/ directory when present
 * (self-healing against target-list drift in build-native.mjs), with the
 * static list as a fallback.
 */
import { existsSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const PKG_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const FALLBACK = ["darwin-arm64", "darwin-x64", "linux-x64", "linux-arm64", "linux-x64-musl", "linux-arm64-musl", "win32-x64"];

function platformList() {
  const npmDir = join(PKG_ROOT, "npm");
  if (existsSync(npmDir)) {
    const built = readdirSync(npmDir).filter((e) => existsSync(join(npmDir, e, "package.json")));
    if (built.length > 0) return built.sort();
  }
  return FALLBACK;
}

const path = join(PKG_ROOT, "package.json");
const pkg = JSON.parse(readFileSync(path, "utf8"));
const platforms = platformList();
pkg.optionalDependencies = Object.fromEntries(platforms.map((p) => [`@zigfitsio/${p}`, pkg.version]));
writeFileSync(path, JSON.stringify(pkg, null, 2) + "\n");
console.log(`injected ${platforms.length} optionalDependencies at ${pkg.version}: ${platforms.join(", ")}`);
