/**
 * Mirror of `bindings/python/tests/test_lowlevel.py` plus ABI hardening:
 * struct-offset tripwires, the float-by-value compression args (the
 * `use_llvm` bug class), and the single allocate-and-return API.
 */
import { describe, expect, test } from "./_harness/index.js";
import { FitsError, FitsOverflowError, KeywordNotFound } from "../src/errors.js";
import * as ll from "../src/lowlevel/index.js";
import { BUF_DIRS, openWasmLibrary, type WasmExports } from "../src/ffi/wasm.js";
import { PROTOS } from "../src/lowlevel/protos.js";
import { enc } from "../src/util.js";

function createMemory(optsBuf: Uint8Array | null = null): bigint {
  const out = ll.outU64();
  ll.check(ll.lib.zf_create_memory(optsBuf, out));
  return out[0];
}

function emptyPrimary(h: bigint): void {
  ll.check(ll.lib.zf_create_img(h, 8, 0, null));
}

function fileBytes(h: bigint): Uint8Array {
  const size = ll.outU64();
  ll.check(ll.lib.zf_data_size(h, size));
  const buf = new Uint8Array(Number(size[0]));
  const got = ll.outU64();
  ll.check(ll.lib.zf_read_bytes(h, 0n, buf, buf.length, got));
  expect(Number(got[0])).toBe(buf.length);
  return buf;
}

describe("lowlevel basics", () => {
  test("version() looks like a semver string", () => {
    expect(ll.version()).toMatch(/^\d+\.\d+\.\d+/);
  });

  test("in-memory f32 image roundtrip through raw zf_* calls", () => {
    const h = createMemory();
    try {
      const axes = ll.longArray([4, 3]);
      ll.check(ll.lib.zf_create_img(h, -32, 2, axes));
      const pix = Float32Array.from({ length: 12 }, (_, i) => i * 1.5);
      ll.check(ll.lib.zf_write_img(h, ll.ZF_FLOAT32, 1n, 12n, null, null, pix));

      const out = new Float32Array(12);
      ll.check(ll.lib.zf_read_img(h, ll.ZF_FLOAT32, 1n, 12n, null, null, out));
      expect(Array.from(out)).toEqual(Array.from(pix));

      const nhdu = ll.newLongArray(1);
      ll.check(ll.lib.zf_hdu_count(h, nhdu));
      expect(ll.readLongAt(nhdu, 0)).toBe(1);

      const kind = ll.outI32();
      ll.check(ll.lib.zf_hdu_type(h, kind));
      expect(kind[0]).toBe(ll.HDU_PRIMARY);
    } finally {
      ll.lib.zf_close(h);
    }
  });

  test("missing keyword raises typed KeywordNotFound (status 202) with a message", () => {
    const h = createMemory();
    try {
      emptyPrimary(h);
      const name = enc("NOPE");
      const out = ll.outI64();
      let caught: unknown = null;
      try {
        ll.check(ll.lib.zf_read_key_lng(h, name, name.length, out));
      } catch (e) {
        caught = e;
      }
      expect(caught).toBeInstanceOf(KeywordNotFound);
      expect(caught).toBeInstanceOf(FitsError);
      expect((caught as FitsError).status).toBe(202);
      expect((caught as FitsError).message.length).toBeGreaterThan(5);
      expect(ll.lastErrorMessage().length).toBeGreaterThan(0);
      expect(Number(ll.lib.zf_last_status())).toBe(202);
    } finally {
      ll.lib.zf_close(h);
    }
  });

  test("zf_key_exists returns 0/1 directly", () => {
    const h = createMemory();
    try {
      emptyPrimary(h);
      const simple = enc("SIMPLE");
      const nope = enc("NOPE");
      expect(Number(ll.lib.zf_key_exists(h, simple, simple.length))).toBe(1);
      expect(Number(ll.lib.zf_key_exists(h, nope, nope.length))).toBe(0);
    } finally {
      ll.lib.zf_close(h);
    }
  });
});

describe("packed VLA ABI", () => {
  test("P/Q layouts, empty cells, BigInt values, complex scalar slots, and zero rows", () => {
    const h = createMemory();
    try {
      emptyPrimary(h);
      ll.check(ll.lib.zf_create_tbl_heap(h, ll.BINARY_TBL, 3n, 3, ["P", "Q", "C"], ["1PJ", "1QK", "1PC"], null, null, 64n));
      const tout = ll.outU64();
      ll.check(ll.lib.zf_table_open(h, tout));
      const t = tout[0];
      try {
        const poff = BigUint64Array.from([0n, 3n, 4n, 4n]);
        ll.check(ll.lib.zf_write_col_vla_packed(t, ll.ZF_INT32, 0, 1n, 3n, poff, poff.length, Int32Array.from([1, 2, 3, 4]), 4n));
        const qoff = BigUint64Array.from([0n, 1n, 3n, 3n]);
        const qvals = BigInt64Array.from([9007199254740993n, -9007199254740995n, 17n]);
        ll.check(ll.lib.zf_write_col_vla_packed(t, ll.ZF_INT64, 1, 1n, 3n, qoff, qoff.length, qvals, 3n));
        ll.check(ll.lib.zf_write_col_vla(t, ll.ZF_FLOAT32, 2, 1n, Float32Array.from([1, -2]), 2n));
        ll.check(ll.lib.zf_write_col_vla(t, ll.ZF_FLOAT32, 2, 2n, Float32Array.from([3, 4, -5, 6]), 4n));

        for (const [col, want] of [
          [0, [0n, 3n, 4n, 4n]],
          [1, [0n, 1n, 3n, 3n]],
          [2, [0n, 2n, 6n, 6n]],
        ] as const) {
          const got = new BigUint64Array(4);
          const total = ll.outU64();
          ll.check(ll.lib.zf_read_col_vla_layout(t, col, 1n, 3n, got, got.length, total));
          expect(Array.from(got)).toEqual(want);
          expect(total[0]).toBe(want[3]);
        }

        const pgot = new Int32Array(4);
        ll.check(ll.lib.zf_read_col_vla_packed(t, ll.ZF_INT32, 0, 1n, 3n, pgot, 4n));
        expect(Array.from(pgot)).toEqual([1, 2, 3, 4]);
        const qgot = new BigInt64Array(3);
        ll.check(ll.lib.zf_read_col_vla_packed(t, ll.ZF_INT64, 1, 1n, 3n, qgot, 3n));
        expect(Array.from(qgot)).toEqual(Array.from(qvals));
        const cgot = new Float32Array(6);
        ll.check(ll.lib.zf_read_col_vla_packed(t, ll.ZF_FLOAT32, 2, 1n, 3n, cgot, 6n));
        expect(Array.from(cgot)).toEqual([1, -2, 3, 4, -5, 6]);

        const emptyLayout = BigUint64Array.from([99n]);
        const emptyTotal = BigUint64Array.from([99n]);
        ll.check(ll.lib.zf_read_col_vla_layout(t, 0, 1n, 0n, emptyLayout, 1, emptyTotal));
        expect(Array.from(emptyLayout)).toEqual([0n]);
        expect(emptyTotal[0]).toBe(0n);
        ll.check(ll.lib.zf_read_col_vla_packed(t, ll.ZF_INT32, 0, 1n, 0n, null, 0n));
      } finally {
        ll.lib.zf_table_close(t);
      }
    } finally {
      ll.lib.zf_close(h);
    }
  });
});

describe("struct-offset tripwires", () => {
  test("ZfColInfo layout: fresh unscaled J column reads back exactly", () => {
    const h = createMemory();
    try {
      emptyPrimary(h);
      ll.check(ll.lib.zf_create_tbl(h, ll.BINARY_TBL, 2n, 2, ["A", "B"], ["1J", "1E"], null, "T1"));

      const tout = ll.outU64();
      ll.check(ll.lib.zf_table_open(h, tout));
      const t = tout[0];
      try {
        const buf = ll.newColInfoBuf();
        ll.check(ll.lib.zf_table_col_info(t, 0, buf));
        const info = ll.decodeColInfo(buf);
        expect(info.typecode).toBe(ll.ZF_INT32);
        expect(info.repeat).toBe(1);
        expect(info.width).toBe(4);
        expect(info.isVla).toBe(false);
        expect(info.tformChar).toBe("J");
        expect(info.tscal).toBe(1.0);
        expect(info.tzero).toBe(0.0);
        expect(info.tnull).toBe(0n);
        expect(info.hasTnull).toBe(false);

        const nameBuf = new Uint8Array(80);
        const nameLen = ll.outU64();
        ll.check(ll.lib.zf_table_col_name(t, 1, nameBuf, nameBuf.length, nameLen));
        expect(new TextDecoder().decode(nameBuf.subarray(0, Number(nameLen[0])))).toBe("B");
      } finally {
        ll.lib.zf_table_close(t);
      }
    } finally {
      ll.lib.zf_close(h);
    }
  });

  test("ZfOpenOpts layout: max_naxis_product limit is enforced on open (status 412)", () => {
    // Build a valid in-memory file with an 8x8 image (naxis product 64).
    const h = createMemory();
    let bytes: Uint8Array;
    try {
      const axes = ll.longArray([8, 8]);
      ll.check(ll.lib.zf_create_img(h, 8, 2, axes));
      const pix = new Uint8Array(64);
      ll.check(ll.lib.zf_write_img(h, ll.ZF_UINT8, 1n, 64n, null, null, pix));
      ll.check(ll.lib.zf_flush(h));
      bytes = fileBytes(h);
    } finally {
      ll.lib.zf_close(h);
    }

    // Reopening with a limit below 64 must fail with LimitExceeded (412) —
    // proving the u64 field at offset 16 landed where the C side reads it.
    const opts = ll.encodeOpenOpts({ maxNaxisProduct: 16 });
    const out = ll.outU64();
    let caught: unknown = null;
    try {
      ll.check(ll.lib.zf_open_memory(bytes, bytes.length, ll.READONLY, opts, out));
      ll.lib.zf_close(out[0]);
    } catch (e) {
      caught = e;
    }
    expect(caught).toBeInstanceOf(FitsOverflowError);
    expect((caught as FitsError).status).toBe(412);

    // And the same file opens fine with a permissive limit (offset sanity both ways).
    const okOpts = ll.encodeOpenOpts({ maxNaxisProduct: 4096 });
    const out2 = ll.outU64();
    ll.check(ll.lib.zf_open_memory(bytes, bytes.length, ll.READONLY, okOpts, out2));
    ll.lib.zf_close(out2[0]);
  });
});

describe("compression ABI crossing (float-by-value args — the use_llvm bug class)", () => {
  test("zf_write_compressed RICE roundtrip through zf_read_img", () => {
    const h = createMemory();
    try {
      emptyPrimary(h);
      const ramp = Int32Array.from({ length: 256 }, (_, i) => i);
      const axes = ll.longArray([16, 16]);
      ll.check(ll.lib.zf_write_compressed(h, ll.ZF_INT32, 32, 2, axes, null, "RICE_1", null, 1n, ramp, 256n));

      ll.check(ll.lib.zf_select(h, 2));
      const out = new Int32Array(256);
      ll.check(ll.lib.zf_read_img(h, ll.ZF_INT32, 1n, 256n, null, null, out));
      expect(Array.from(out)).toEqual(Array.from(ramp));
    } finally {
      ll.lib.zf_close(h);
    }
  });

  test("zf_write_compressed2 (13 args): hcomp_scale/smooth land in the right slots", () => {
    const h = createMemory();
    try {
      emptyPrimary(h);
      const curved = new Int32Array(256);
      for (let r = 0; r < 16; r++) for (let c = 0; c < 16; c++) curved[r * 16 + c] = r * r + 2 * c * c + r * c;
      const axes = ll.longArray([16, 16]);
      const tile = ll.longArray([16, 16]);
      ll.check(
        ll.lib.zf_write_compressed2(h, ll.ZF_INT32, 32, 2, axes, tile, "HCOMPRESS_1", null, 1n, -16.0, 1, curved, 256n),
      );

      // The recorded request cards: ZVAL1 = -16.0 (the f32 arg), ZVAL2 = 1 (smooth).
      ll.check(ll.lib.zf_select(h, 2));
      const zval1 = ll.outF64();
      const k1 = enc("ZVAL1");
      ll.check(ll.lib.zf_read_key_dbl(h, k1, k1.length, zval1));
      expect(zval1[0]).toBe(-16.0);
      const zval2 = ll.outI64();
      const k2 = enc("ZVAL2");
      ll.check(ll.lib.zf_read_key_lng(h, k2, k2.length, zval2));
      expect(zval2[0]).toBe(1n);

      // Transparent decode: genuinely lossy, but within the scale-16 bound.
      const out = new Int32Array(256);
      ll.check(ll.lib.zf_read_img(h, ll.ZF_INT32, 1n, 256n, null, null, out));
      let maxerr = 0;
      for (let i = 0; i < 256; i++) maxerr = Math.max(maxerr, Math.abs(curved[i] - out[i]));
      expect(maxerr).toBeGreaterThan(0);
      expect(maxerr).toBeLessThanOrEqual(64 * 16);

      // Knob misuse crosses as an error status, not an abort: RICE + hcomp_scale.
      expect(Number(ll.lib.zf_write_compressed2(h, ll.ZF_INT32, 32, 2, axes, tile, "RICE_1", null, 1n, -4.0, 0, curved, 256n))).not.toBe(0);
    } finally {
      ll.lib.zf_close(h);
    }
  });

  test("zf_write_compressed3 (15 args): quantize_level plumbed, gates fail loud", () => {
    const h = createMemory();
    try {
      emptyPrimary(h);
      // A positive noisy field; absolute step 0.25 gives a deterministic bound.
      const pix = new Float32Array(256);
      let state = 999 >>> 0;
      for (let i = 0; i < 256; i++) {
        state = (Math.imul(state, 1664525) + 1013904223) >>> 0;
        pix[i] = Math.fround(10.0 + (i % 16) + (state >>> 24) / 64.0);
      }
      const axes = ll.longArray([16, 16]);
      ll.check(
        ll.lib.zf_write_compressed3(
          h, ll.ZF_FLOAT32, -32, 2, axes, null, "HCOMPRESS_1", "SUBTRACTIVE_DITHER_1", 1n,
          -0.25, 1, 0.0, 0, pix, 256n,
        ),
      );

      ll.check(ll.lib.zf_select(h, 2));
      const out = new Float32Array(256);
      ll.check(ll.lib.zf_read_img(h, ll.ZF_FLOAT32, 1n, 256n, null, null, out));
      for (let i = 0; i < 256; i++) expect(Math.abs(pix[i] - out[i])).toBeLessThanOrEqual(0.125 + 1e-5);

      // A set quantize_level on a non-quantizing write is an error status, never silent.
      const ints = Int32Array.from({ length: 256 }, (_, i) => i);
      expect(
        Number(ll.lib.zf_write_compressed3(h, ll.ZF_INT32, 32, 2, axes, null, "RICE_1", null, 1n, 4.0, 1, 0.0, 0, ints, 256n)),
      ).not.toBe(0);
      // has_quantize_level = 0 leaves the level unset: the same integer write succeeds.
      ll.check(ll.lib.zf_write_compressed3(h, ll.ZF_INT32, 32, 2, axes, null, "RICE_1", null, 1n, 0.0, 0, 0.0, 0, ints, 256n));
    } finally {
      ll.lib.zf_close(h);
    }
  });
});

describe("allocate-and-return", () => {
  test("zf_read_key_longstr + readCString + zf_free", () => {
    const h = createMemory();
    try {
      emptyPrimary(h);
      const key = enc("LONGKEY");
      const value = "a rather long string value ".repeat(6).trim();
      const vbytes = enc(value);
      ll.check(ll.lib.zf_write_key_longstr(h, key, key.length, vbytes, vbytes.length, null, 0));

      const outPtr = ll.outU64();
      const outLen = ll.outU64();
      ll.check(ll.lib.zf_read_key_longstr(h, key, key.length, outPtr, outLen));
      const ptr = outPtr[0];
      const len = Number(outLen[0]);
      expect(ptr).not.toBe(0n);
      try {
        expect(ll.native.readCString(ptr, len)).toBe(value);
      } finally {
        ll.lib.zf_free(ptr, len);
      }
    } finally {
      ll.lib.zf_close(h);
    }
  });
});

// Tripwire for the WASM backend's copy-direction optimization: every index it annotates as a
// one-way ("in"/"out") buffer must actually be a `buf` argument at that position in the proto,
// so a future reordering of the C ABI can never silently skip a needed copy-in/copy-back.
describe("wasm buf-direction map", () => {
  const byName = new Map(PROTOS.map((p) => [p.name, p]));
  test("prototype count and packed VLA directions match the ABI", () => {
    expect(PROTOS).toHaveLength(89);
    expect(BUF_DIRS.zf_read_col_vla_layout).toEqual({ 4: "out", 6: "out" });
    expect(BUF_DIRS.zf_read_col_vla_packed).toEqual({ 5: "out" });
    expect(BUF_DIRS.zf_write_col_vla_packed).toEqual({ 5: "in", 7: "in" });
  });
  for (const [name, dirs] of Object.entries(BUF_DIRS)) {
    test(`${name}: annotated indices are buf args`, () => {
      const proto = byName.get(name);
      expect(proto, `unknown symbol ${name}`).toBeDefined();
      for (const idx of Object.keys(dirs).map(Number)) {
        expect(proto!.args[idx], `${name} arg[${idx}] must be "buf"`).toBe("buf");
      }
    });
  }
});

describe("wasm32 marshalling limits", () => {
  test("oversized, negative, and unsafe buffer/usize lengths fail before wasm coercion", () => {
    let allocations = 0;
    const ex = {
      memory: new WebAssembly.Memory({ initial: 1 }),
      zf_walloc: () => {
        allocations++;
        return 8;
      },
      zf_wfree: () => undefined,
      zf_test_buf: () => 0,
      zf_test_usize: () => 0,
    } as unknown as WasmExports;
    const lib = openWasmLibrary(ex, [
      { name: "zf_test_buf", returns: "int", args: ["buf"] },
      { name: "zf_test_usize", returns: "int", args: ["usize"] },
    ]);
    const fake = (byteLength: number): ArrayBufferView =>
      ({ buffer: new ArrayBuffer(0), byteOffset: 0, byteLength } as ArrayBufferView);
    for (const bad of [-1, 0x1_0000_0000, Number.MAX_SAFE_INTEGER + 1]) {
      expect(() => lib.fn.zf_test_buf(fake(bad))).toThrow(RangeError);
      expect(() => lib.fn.zf_test_usize(bad)).toThrow(RangeError);
    }
    expect(allocations).toBe(0);
  });
});
