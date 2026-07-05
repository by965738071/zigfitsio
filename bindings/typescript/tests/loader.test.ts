import { describe, expect, test } from "./_harness/index.js";
import { isBun, openNativeLibrary } from "../src/ffi/index.js";
import { candidatePaths, findLibrary, libFilename } from "../src/loader.js";

describe("loader", () => {
  test("libFilename matches the platform", () => {
    const name = libFilename();
    if (process.platform === "darwin") expect(name).toBe("libzigfitsio_capi.dylib");
    else if (process.platform === "win32") expect(name).toBe("zigfitsio_capi.dll");
    else expect(name).toBe("libzigfitsio_capi.so");
  });

  test("ZIGFITSIO_LIBRARY env var is the first candidate", () => {
    const prev = process.env.ZIGFITSIO_LIBRARY;
    process.env.ZIGFITSIO_LIBRARY = "/definitely/not/there.so";
    try {
      expect(candidatePaths()[0]).toBe("/definitely/not/there.so");
    } finally {
      if (prev === undefined) delete process.env.ZIGFITSIO_LIBRARY;
      else process.env.ZIGFITSIO_LIBRARY = prev;
    }
  });

  test("a bad env var falls through to the dev build", () => {
    const prev = process.env.ZIGFITSIO_LIBRARY;
    process.env.ZIGFITSIO_LIBRARY = "/definitely/not/there.so";
    try {
      expect(findLibrary()).toContain("zig-out");
    } finally {
      if (prev === undefined) delete process.env.ZIGFITSIO_LIBRARY;
      else process.env.ZIGFITSIO_LIBRARY = prev;
    }
  });

  test("findLibrary locates the dev build", () => {
    expect(findLibrary()).toContain("zigfitsio_capi");
  });
});

describe("ffi backend", () => {
  test("backend matches the runtime", () => {
    const lib = openNativeLibrary(findLibrary(), [{ name: "zf_version", returns: "cstring_ret", args: [] }]);
    expect(lib.backend).toBe(process.versions?.bun ? "bun" : "koffi");
    expect(isBun).toBe(!!process.versions?.bun);
  });

  test("zf_version returns a semver string", () => {
    const lib = openNativeLibrary(findLibrary(), [{ name: "zf_version", returns: "cstring_ret", args: [] }]);
    const v = lib.fn.zf_version();
    expect(typeof v).toBe("string");
    expect(v).toMatch(/^\d+\.\d+\.\d+/);
  });
});
