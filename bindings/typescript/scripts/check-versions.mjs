#!/usr/bin/env node
/**
 * Assert the TS package version matches the canonical Zig version
 * (build.zig.zon / src/version.zig). Run by CI (typescript.yml version-check)
 * and by prepack.
 */
import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const PKG_ROOT = resolve(HERE, "..");
const REPO_ROOT = resolve(PKG_ROOT, "..", "..");

const zon = readFileSync(join(REPO_ROOT, "build.zig.zon"), "utf8");
const zonVersion = zon.match(/\.version\s*=\s*"([^"]+)"/)?.[1];
const versionZig = readFileSync(join(REPO_ROOT, "src", "version.zig"), "utf8");
const zigVersion = versionZig.match(/version_string\s*=\s*"([^"]+)"/)?.[1];
const pkgVersion = JSON.parse(readFileSync(join(PKG_ROOT, "package.json"), "utf8")).version;

const failures = [];
if (!zonVersion) failures.push("could not parse .version from build.zig.zon");
if (zonVersion !== zigVersion) failures.push(`src/version.zig version_string ${zigVersion} != build.zig.zon ${zonVersion}`);
if (pkgVersion !== zonVersion) failures.push(`bindings/typescript/package.json ${pkgVersion} != build.zig.zon ${zonVersion}`);

if (failures.length > 0) {
  console.error("version check FAILED:");
  for (const f of failures) console.error("  - " + f);
  process.exit(1);
}
console.log(`version check OK: ${zonVersion}`);
