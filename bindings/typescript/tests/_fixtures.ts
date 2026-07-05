/** Shared test fixtures: temp FITS paths and the committed golden corpus. */
import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
export const REPO_ROOT = resolve(HERE, "..", "..", "..");
export const GOLDEN_DIR = join(REPO_ROOT, "test", "golden");
export const hasGolden = existsSync(GOLDEN_DIR);
export const goldenPath = (...parts: string[]): string => join(GOLDEN_DIR, ...parts);
export const hasGoldenFile = (...parts: string[]): boolean => existsSync(goldenPath(...parts));

let counter = 0;

/** A per-test-file temp dir with a fresh-path helper; call `cleanup` in afterAll. */
export function tmpFits(): { path: () => string; cleanup: () => void } {
  const dir = mkdtempSync(join(tmpdir(), "zigfitsio-ts-"));
  return {
    path: () => join(dir, `t${counter++}.fits`),
    cleanup: () => {
      try {
        rmSync(dir, { recursive: true, force: true });
      } catch {
        /* best effort */
      }
    },
  };
}

/** Range helper: a TypedArray filled with `f(i)`. */
export function fill<T extends { length: number }>(arr: T, f: (i: number) => number | bigint): T {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  for (let i = 0; i < arr.length; i++) (arr as any)[i] = f(i);
  return arr;
}
