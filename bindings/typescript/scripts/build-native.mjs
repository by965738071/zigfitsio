#!/usr/bin/env node
/**
 * Cross-compile the zigfitsio_capi shared library for every npm platform
 * package (or one, with --target=<key>) and synthesize the packages under
 * bindings/typescript/npm/<key>/ (package.json + index.cjs + README + the
 * library). Everything under npm/ is generated — nothing is committed.
 *
 * Usage:
 *   node scripts/build-native.mjs               # all 7 targets
 *   node scripts/build-native.mjs --target=darwin-arm64
 *
 * Env: ZIG=/path/to/zig overrides the zig binary.
 */
import { execFileSync } from "node:child_process";
import { copyFileSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const PKG_ROOT = resolve(HERE, "..");
const REPO_ROOT = resolve(PKG_ROOT, "..", "..");

// npm package key -> zig cross target + artifact location. Linux pins glibc
// 2.17 for old-distro portability; macOS pins the 11.0 floor (same as the
// Python wheels — see hatch_build.py). Zig installs Windows DLLs under bin/.
const TARGETS = {
  "linux-x64": { triple: "x86_64-linux-gnu.2.17", sub: "lib", file: "libzigfitsio_capi.so", os: "linux", cpu: "x64", libc: "glibc" },
  "linux-arm64": { triple: "aarch64-linux-gnu.2.17", sub: "lib", file: "libzigfitsio_capi.so", os: "linux", cpu: "arm64", libc: "glibc" },
  "linux-x64-musl": { triple: "x86_64-linux-musl", sub: "lib", file: "libzigfitsio_capi.so", os: "linux", cpu: "x64", libc: "musl" },
  "linux-arm64-musl": { triple: "aarch64-linux-musl", sub: "lib", file: "libzigfitsio_capi.so", os: "linux", cpu: "arm64", libc: "musl" },
  "darwin-x64": { triple: "x86_64-macos.11.0", sub: "lib", file: "libzigfitsio_capi.dylib", os: "darwin", cpu: "x64" },
  "darwin-arm64": { triple: "aarch64-macos.11.0", sub: "lib", file: "libzigfitsio_capi.dylib", os: "darwin", cpu: "arm64" },
  "win32-x64": { triple: "x86_64-windows", sub: "bin", file: "zigfitsio_capi.dll", os: "win32", cpu: "x64" },
};

const mainPkg = JSON.parse(readFileSync(join(PKG_ROOT, "package.json"), "utf8"));
const version = mainPkg.version;
const zig = process.env.ZIG ?? "zig";

const only = process.argv.find((a) => a.startsWith("--target="))?.slice("--target=".length);
const keys = only ? [only] : Object.keys(TARGETS);
for (const key of keys) {
  if (!(key in TARGETS)) {
    console.error(`unknown target ${key}; known: ${Object.keys(TARGETS).join(", ")}`);
    process.exit(2);
  }
}

for (const key of keys) {
  const t = TARGETS[key];
  const prefix = join(REPO_ROOT, "zig-out", "npm-prefix", key);
  console.log(`[${key}] zig build capi -Dtarget=${t.triple} (ReleaseFast)`);
  execFileSync(zig, ["build", "capi", "-Doptimize=ReleaseFast", `-Dtarget=${t.triple}`, "--prefix", prefix], {
    cwd: REPO_ROOT,
    stdio: "inherit",
  });

  const pkgDir = join(PKG_ROOT, "npm", key);
  rmSync(pkgDir, { recursive: true, force: true });
  mkdirSync(pkgDir, { recursive: true });
  copyFileSync(join(prefix, t.sub, t.file), join(pkgDir, t.file));

  const pkg = {
    name: `@zigfitsio/${key}`,
    version,
    description: `zigfitsio prebuilt shared library for ${key}${t.libc ? ` (${t.libc})` : ""}`,
    main: "index.cjs",
    files: ["index.cjs", t.file, "LICENSE"],
    license: "MIT",
    repository: mainPkg.repository,
    os: [t.os],
    cpu: [t.cpu],
    ...(t.libc ? { libc: [t.libc] } : {}),
    publishConfig: { access: "public" },
  };
  writeFileSync(join(pkgDir, "package.json"), JSON.stringify(pkg, null, 2) + "\n");
  copyFileSync(join(REPO_ROOT, "LICENSE"), join(pkgDir, "LICENSE"));
  writeFileSync(
    join(pkgDir, "index.cjs"),
    `module.exports = require("node:path").join(__dirname, ${JSON.stringify(t.file)});\n`,
  );
  writeFileSync(
    join(pkgDir, "README.md"),
    `# @zigfitsio/${key}\n\nPrebuilt \`zigfitsio_capi\` shared library for ${key}. ` +
      `This is a platform package of [zigfitsio](https://www.npmjs.com/package/zigfitsio); ` +
      `install \`zigfitsio\` instead of depending on this directly.\n`,
  );
  console.log(`[${key}] -> npm/${key}/ (v${version})`);
}
