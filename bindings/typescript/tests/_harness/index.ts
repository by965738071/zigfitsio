/**
 * Runner-agnostic test harness: `bun test` provides bun:test, everything else
 * (the Node lane) uses vitest. Both expose the same jest-style subset used by
 * this suite. Runtime detection keeps the two runners out of each other's
 * module graphs (require("bun:test") only executes under Bun; the vitest
 * dynamic import only executes under Node).
 */
import { createRequire } from "node:module";

interface HarnessImpl {
  describe: (name: string, fn: () => void) => void;
  test: ((name: string, fn: () => void | Promise<void>) => void) & {
    skip: (name: string, fn: () => void | Promise<void>) => void;
    skipIf?: (cond: boolean) => (name: string, fn: () => void | Promise<void>) => void;
  };
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  expect: any;
  beforeAll: (fn: () => void | Promise<void>) => void;
  afterAll: (fn: () => void | Promise<void>) => void;
}

const impl: HarnessImpl = process.versions?.bun
  ? createRequire(import.meta.url)("bun:test")
  : ((await import("vitest")) as unknown as HarnessImpl);

export const describe = impl.describe;
export const test = impl.test;
export const expect = impl.expect;
export const beforeAll = impl.beforeAll;
export const afterAll = impl.afterAll;

/** Skip helper that works on both runners. */
export function testIf(cond: boolean): (name: string, fn: () => void | Promise<void>) => void {
  return cond ? impl.test : impl.test.skip.bind(impl.test);
}
