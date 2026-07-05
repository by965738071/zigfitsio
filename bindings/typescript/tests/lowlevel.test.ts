/**
 * Mirror of `bindings/python/tests/test_lowlevel.py` plus ABI hardening:
 * struct-offset tripwires, the float-by-value compression args (the
 * `use_llvm` bug class), and the single allocate-and-return API.
 */
import { describe, expect, test } from "./_harness/index.js";
import { FitsError, FitsOverflowError, KeywordNotFound } from "../src/errors.js";
import * as ll from "../src/lowlevel/index.js";
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
