import { describe, expect, test } from "./_harness/index.js";
import { openWasmLibrary } from "../src/ffi/index.js";
import { findWasm, wasmBytesSync } from "../src/loader.js";
import * as ll from "../src/lowlevel/index.js";

const PROTO = [{ name: "zf_version", returns: "cstring_ret", args: [] as const }] as const;

function instantiate(): WebAssembly.Exports {
  const inst = new WebAssembly.Instance(new WebAssembly.Module(wasmBytesSync()), {});
  return inst.exports;
}

describe("loader", () => {
  test("ZIGFITSIO_WASM env var is the first candidate honored", () => {
    const prev = process.env.ZIGFITSIO_WASM;
    process.env.ZIGFITSIO_WASM = "/definitely/not/there.wasm";
    try {
      // A bad explicit path falls through to the dev build under zig-out/bin.
      expect(findWasm()).toContain("zig-out");
    } finally {
      if (prev === undefined) delete process.env.ZIGFITSIO_WASM;
      else process.env.ZIGFITSIO_WASM = prev;
    }
  });

  test("findWasm locates the dev build", () => {
    expect(findWasm()).toContain("zigfitsio.wasm");
  });
});

describe("wasm backend", () => {
  test("backend is wasm and the module has zero imports", () => {
    const bytes = wasmBytesSync();
    expect(WebAssembly.Module.imports(new WebAssembly.Module(bytes)).length).toBe(0);
    const lib = openWasmLibrary(instantiate() as never, PROTO);
    expect(lib.backend).toBe("wasm");
  });

  test("zf_version returns a semver string", () => {
    const lib = openWasmLibrary(instantiate() as never, PROTO);
    const v = lib.fn.zf_version();
    expect(typeof v).toBe("string");
    expect(v).toMatch(/^\d+\.\d+\.\d+/);
  });

  test("isReady() is true on Node/Bun (synchronous init at import)", () => {
    expect(ll.isReady()).toBe(true);
  });
});
