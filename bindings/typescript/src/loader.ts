/**
 * Locate the `zigfitsio_capi` shared library (mirror of the Python
 * `_loader.py`). Search order:
 *
 *   1. `ZIGFITSIO_LIBRARY` env var (an explicit path to the shared library).
 *   2. The bundled `@zigfitsio/<platform>` npm package.
 *   3. A development build under `<repo>/zig-out/{lib|bin}` discovered by
 *      walking parents of this file and of the working directory.
 */
import { existsSync, readdirSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export function libFilename(): string {
  if (process.platform === "darwin") return "libzigfitsio_capi.dylib";
  if (process.platform === "win32") return "zigfitsio_capi.dll";
  return "libzigfitsio_capi.so";
}

function isMusl(): boolean {
  try {
    // Node and Bun both implement process.report on linux.
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const report: any = (process as any).report?.getReport?.();
    if (report?.header) return !report.header.glibcVersionRuntime;
  } catch {
    /* fall through to the loader-file probe */
  }
  try {
    return readdirSync("/lib").some((f) => f.startsWith("ld-musl-"));
  } catch {
    return false;
  }
}

/** `<platform>-<arch>[-musl]`, the suffix of the platform npm package name. */
export function platformKey(): string {
  const base = `${process.platform}-${process.arch}`;
  return process.platform === "linux" && isMusl() ? `${base}-musl` : base;
}

export function candidatePaths(): string[] {
  const name = libFilename();
  const candidates: string[] = [];

  const env = process.env.ZIGFITSIO_LIBRARY;
  if (env) candidates.push(env);

  // Bundled platform package. Resolved via its package.json so the package
  // needs no exports map for the library file itself.
  try {
    const req = createRequire(import.meta.url);
    const pkgJson = req.resolve(`@zigfitsio/${platformKey()}/package.json`);
    candidates.push(join(dirname(pkgJson), name));
  } catch {
    /* platform package not installed */
  }

  // Development fallback: zig-out/{bin|lib} somewhere above. Zig installs the
  // Windows DLL under bin/ (only the import .lib lands in lib/); .so/.dylib
  // live under lib/.
  const subdir = process.platform === "win32" ? "bin" : "lib";
  const roots = [dirname(fileURLToPath(import.meta.url)), process.cwd()];
  outer: for (const root of roots) {
    let dir = resolve(root);
    for (;;) {
      const cand = join(dir, "zig-out", subdir, name);
      if (existsSync(cand)) {
        candidates.push(cand);
        break outer;
      }
      const parent = dirname(dir);
      if (parent === dir) break;
      dir = parent;
    }
  }

  return candidates;
}

/** Return the first existing candidate path, or throw listing every path tried. */
export function findLibrary(): string {
  const tried: string[] = [];
  for (const path of candidatePaths()) {
    tried.push(path);
    if (existsSync(path)) return path;
  }
  throw new Error(
    "could not locate the zigfitsio_capi shared library. Build it with " +
      "`zig build capi` or set ZIGFITSIO_LIBRARY. Searched:\n  " +
      tried.join("\n  "),
  );
}
